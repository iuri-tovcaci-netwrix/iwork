package index

import (
	"archive/zip"
	"bytes"
	"database/sql"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"path"
	"strings"

	"github.com/dunhamsteve/iwork/proto/TSP"

	"github.com/golang/protobuf/proto"
	"github.com/golang/snappy"

	// register sqlite3 driver
	_ "github.com/mattn/go-sqlite3"
)

// Index holds the content of an iwork file
type Index struct {
	Type    string                 `json:"type"`
	Records map[uint64]interface{} `json:"records"`
}

// Open loads a document into an Index structure
func Open(doc string) (*Index, error) {
	fn := path.Join(doc, "Index.zip")
	zf, err := zip.OpenReader(fn)
	if err != nil {
		// iWork 5.5
		zf, err = zip.OpenReader(doc)
	}
	if err == nil {
		defer zf.Close()
		// Detect type from content
		indexType, err := detectTypeFromZip(&zf.Reader)
		if err != nil {
			return nil, fmt.Errorf("failed to detect file type: %w", err)
		}
		ix := &Index{indexType, nil}
		err = ix.loadZip(zf)
		return ix, err
	}

	// .pages-tef files, sqlite
	fn = path.Join(doc, "index.db")
	_, err = os.Stat(fn)
	if err == nil {
		db, err := sql.Open("sqlite3", fn)
		if err == nil {
			defer db.Close()
			indexType, err := detectTypeFromSQL(db)
			if err != nil {
				return nil, fmt.Errorf("failed to detect file type: %w", err)
			}
			ix := &Index{indexType, nil}
			err = ix.loadSQL(db)
			return ix, err
		}
	}

	return nil, err
}

// detectTypeFromZip probes the zip contents to determine the iWork document type
func detectTypeFromZip(zr *zip.Reader) (string, error) {
	typeIDs := make(map[uint32]bool)

	// Find and parse the first .iwa file to collect type IDs
	for _, f := range zr.File {
		if strings.HasSuffix(f.Name, ".iwa") {
			rc, err := f.Open()
			if err != nil {
				continue
			}
			data, err := ioutil.ReadAll(rc)
			rc.Close()
			if err != nil {
				continue
			}

			// Collect type IDs from this .iwa file
			ids, err := extractTypeIDs(data)
			if err != nil {
				continue
			}
			for _, id := range ids {
				typeIDs[id] = true
			}

			// Check if we have enough info to determine type
			if docType := determineTypeFromIDs(typeIDs); docType != "" {
				return docType, nil
			}
		}
	}

	// Final attempt with all collected IDs
	if docType := determineTypeFromIDs(typeIDs); docType != "" {
		return docType, nil
	}

	return "", errors.New("unable to determine document type from content")
}

// detectTypeFromSQL probes the SQLite database to determine the iWork document type
func detectTypeFromSQL(db *sql.DB) (string, error) {
	typeIDs := make(map[uint32]bool)

	stmt := `select o.class from objects o limit 100`
	rows, err := db.Query(stmt)
	if err != nil {
		return "", err
	}
	defer rows.Close()

	for rows.Next() {
		var class uint32
		if err := rows.Scan(&class); err != nil {
			continue
		}
		typeIDs[class] = true
	}

	if docType := determineTypeFromIDs(typeIDs); docType != "" {
		return docType, nil
	}

	return "", errors.New("unable to determine document type from content")
}

// extractTypeIDs extracts protobuf type IDs from an .iwa file without fully decoding
func extractTypeIDs(data []byte) ([]uint32, error) {
	data, err := unsnap(data)
	if err != nil {
		return nil, err
	}

	var ids []uint32
	r := bytes.NewBuffer(data)
	for {
		l, err := binary.ReadUvarint(r)
		if err == io.EOF {
			break
		}
		if err != nil {
			return ids, err
		}

		chunk := make([]byte, l)
		_, err = r.Read(chunk)
		if err != nil {
			return ids, err
		}

		var ai TSP.ArchiveInfo
		err = proto.Unmarshal(chunk, &ai)
		if err != nil {
			return ids, err
		}

		for _, info := range ai.MessageInfos {
			ids = append(ids, *info.Type)
			// Skip the payload
			payload := make([]byte, *info.Length)
			r.Read(payload)
		}
	}
	return ids, nil
}

// determineTypeFromIDs determines document type based on protobuf type IDs
func determineTypeFromIDs(typeIDs map[uint32]bool) string {
	// Type ID 10000 = TP.DocumentArchive (Pages-specific)
	if typeIDs[10000] {
		return "pages"
	}

	// Type ID 6001 = TST.DataStore, 6005 = TST.TableDataList (Numbers-specific table types)
	if typeIDs[6001] || typeIDs[6005] {
		return "numbers"
	}

	// Type ID 5 = KN.SlideArchive (Keynote-specific)
	if typeIDs[5] {
		return "key"
	}

	// Secondary checks for Numbers (table-related types 6000-6256)
	for id := uint32(6000); id <= 6256; id++ {
		if typeIDs[id] {
			return "numbers"
		}
	}

	// Secondary checks for Keynote (build/transition types 100-148)
	for id := uint32(100); id <= 148; id++ {
		if typeIDs[id] {
			return "key"
		}
	}

	return ""
}

func (ix *Index) loadSQL(db *sql.DB) error {
	ix.Records = make(map[uint64]interface{})
	stmt := `select o.identifier, o.class, ds.state from objects o join dataStates ds on o.state = ds.identifier`
	rows, err := db.Query(stmt)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id uint64
		var class uint32
		var data []byte
		err = rows.Scan(&id, &class, &data)
		if err != nil {
			return err
		}
		ix.decodePayload(id, class, data)
	}
	return nil
}

func (ix *Index) loadZip(zf *zip.ReadCloser) error {
	ix.Records = make(map[uint64]interface{})
	for _, f := range zf.File {
		if strings.HasSuffix(f.Name, ".iwa") {
			rc, err := f.Open()
			if err != nil {
				return err
			}
			defer rc.Close()

			data, err := ioutil.ReadAll(rc)
			if err != nil {
				return err
			}
			err = ix.loadIWA(data)
			if err != nil {
				return err
			}
		}
	}
	return nil
}

// Deref returns the object pointed to by a TSP.Reference
func (ix *Index) Deref(ref *TSP.Reference) interface{} {
	if ref == nil {
		return nil
	}
	return ix.Records[*ref.Identifier]
}

func (ix *Index) loadIWA(data []byte) error {
	data, err := unsnap(data)
	if err != nil {
		return err
	}

	r := bytes.NewBuffer(data)
	for {
		l, err := binary.ReadUvarint(r)
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		chunk := make([]byte, l)
		_, err = r.Read(chunk)
		if err != nil {
			return err
		}
		var ai TSP.ArchiveInfo
		err = proto.Unmarshal(chunk, &ai)
		if err != nil {
			return err
		}

		for _, info := range ai.MessageInfos {
			payload := make([]byte, *info.Length)
			_, err := r.Read(payload)
			if err != nil {
				return err
			}

			id, typ := *ai.Identifier, *info.Type

			ix.decodePayload(id, typ, payload)
		}
	}
	return nil
}

func (ix *Index) decodePayload(id uint64, typ uint32, payload []byte) {
	var value interface{}
	var err error
	if ix.Type == "pages" {
		value, err = decodePages(typ, payload)
	} else if ix.Type == "numbers" {
		value, err = decodeNumbers(typ, payload)
	} else if ix.Type == "key" {
		value, err = decodeKeynote(typ, payload)
	} else {
		fmt.Fprintln(os.Stderr, "Cannot decode files of type", ix.Type)
	}

	if err != nil {
		// These we don't care as much about
		fmt.Fprintln(os.Stderr, "ERR", id, typ, err)
		return
	}

	ix.Records[id] = value
}

func unsnap(data []byte) ([]byte, error) {
	rval := bytes.NewBuffer(nil)
	for len(data) > 0 {
		typ := int(data[0])
		if typ != 0 {
			return nil, errors.New("snap header type not 0")
		}
		l := int(data[1]) | int(data[2])<<8 | int(data[3])<<16
		tmp, err := snappy.Decode(nil, data[4:4+l])
		if err != nil {
			return nil, err
		}
		rval.Write(tmp)
		data = data[4+l:]
	}
	return rval.Bytes(), nil
}
