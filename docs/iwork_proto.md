# iWork File Format: Protocol Buffer Extraction Guide

This document describes how to extract Protocol Buffer definitions from Apple's iWork applications (Keynote, Pages, Numbers) to enable reading and writing `.key`, `.pages`, and `.numbers` files.

## Table of Contents

1. [Overview](#overview)
2. [File Format Structure](#file-format-structure)
3. [The Extraction Process](#the-extraction-process)
4. [Project Integration](#project-integration)
5. [Step-by-Step Guide](#step-by-step-guide)
6. [Dependencies](#dependencies)
7. [Troubleshooting](#troubleshooting)
8. [Related Projects](#related-projects)
9. [References](#references)

---

## Overview

iWork files use a proprietary format built on top of several open-source technologies:

| Technology | Purpose |
|------------|---------|
| **ZIP** | Bundle packaging (Index.zip contains all serialized data) |
| **Snappy** | Compression (Google's fast compression algorithm) |
| **Protocol Buffers** | Data serialization (Google's binary format) |

**Key Insight**: Apple embeds compiled `FileDescriptorProto` messages directly in iWork application binaries. These contain the complete `.proto` definitions and can be extracted without needing source code.

---

## File Format Structure

### Bundle Layout

An iWork document is a macOS bundle (directory) with this structure:

```
Document.key/
├── Data/                           # Media files
│   ├── image-001.jpg
│   ├── video-001.mov
│   └── ...
├── Index.zip                       # Serialized object graph
│   └── Index/
│       ├── Document.iwa            # Main document metadata
│       ├── DocumentStylesheet.iwa  # Styles
│       ├── Slide-00001.iwa         # Individual slides/pages
│       ├── Tables/
│       │   └── Tile-*.iwa          # Table data
│       └── ...
├── Metadata/
│   ├── BuildVersionHistory.plist
│   ├── DocumentIdentifier
│   └── Properties.plist
├── preview.jpg                     # Document preview
├── preview-web.jpg
└── preview-micro.jpg
```

### Index.zip Peculiarities

Apple uses an **extremely limited** ZIP implementation:
- No compression (stored only)
- No Zip64 extensions
- Standard zip utilities produce files iWork refuses to open

This appears intentional—possibly for atomic write operations and synchronization.

### IWA File Format

`.iwa` (iWork Archive) files contain Snappy-compressed Protocol Buffer streams:

```
┌─────────────────────────────────────────────────────────────┐
│                    SNAPPY FRAME                              │
├─────────────────────────────────────────────────────────────┤
│  Header (4 bytes)                                            │
│  ├── Chunk type (1 byte): 0x00 = compressed chunk           │
│  └── Chunk length (3 bytes, little-endian, excludes header) │
├─────────────────────────────────────────────────────────────┤
│  Snappy-compressed payload                                   │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  PROTOBUF STREAM (after decompression)                  ││
│  │  ┌─────────────────────────────────────────────────────┐││
│  │  │  Object 0                                           │││
│  │  │  ├── varint: ArchiveInfo length                     │││
│  │  │  ├── ArchiveInfo message                            │││
│  │  │  │   ├── identifier: uint64 (unique object ID)      │││
│  │  │  │   └── message_infos: [MessageInfo]               │││
│  │  │  │       ├── type: uint32 (→ TSPRegistry lookup)    │││
│  │  │  │       ├── version: [uint32] (e.g., [1,0,5])      │││
│  │  │  │       ├── length: uint32                         │││
│  │  │  │       ├── object_references: [uint64]            │││
│  │  │  │       └── data_references: [uint64]              │││
│  │  │  └── Payload (actual protobuf message)              │││
│  │  ├─────────────────────────────────────────────────────┤││
│  │  │  Object 1 ...                                       │││
│  │  ├─────────────────────────────────────────────────────┤││
│  │  │  Object N ...                                       │││
│  │  └─────────────────────────────────────────────────────┘││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

**Note**: iWork's Snappy implementation doesn't strictly follow the spec:
- No Stream Identifier chunk
- No CRC-32C checksums in compressed chunks

### Core Protobuf Messages

```protobuf
message ArchiveInfo {
  optional uint64 identifier = 1;      // Unique across document
  repeated MessageInfo message_infos = 2;
}

message MessageInfo {
  required uint32 type = 1;            // Maps to proto message via TSPRegistry
  repeated uint32 version = 2 [packed = true];  // Format version (e.g., 1.0.5)
  required uint32 length = 3;          // Payload length
  repeated FieldInfo field_infos = 4;  // Optional introspection data
  repeated uint64 object_references = 5 [packed = true];
  repeated uint64 data_references = 6 [packed = true];
}
```

### TSPRegistry Type Mapping

The `MessageInfo.type` field contains a numeric ID. To know which protobuf message to use for decoding, you need the **TSPRegistry** mapping extracted at runtime:

```
148 -> KN.ChartInfoGeometryCommandArchive
147 -> KN.SlideCollectionCommandSelectionBehaviorArchive
146 -> KN.CommandSlideReapplyMasterArchive
...
```

Mappings differ slightly between Keynote, Pages, and Numbers.

---

## The Extraction Process

Two things must be extracted:

| What | Why | How |
|------|-----|-----|
| **Proto Definitions** | Define message structures | Scan binaries for embedded `FileDescriptorProto` |
| **Type Mappings** | Map numeric IDs to message names | Extract `TSPRegistry` via LLDB at runtime |

### Step 1: Proto Extraction

Apple compiles `.proto` files into their applications. The compiled `FileDescriptorProto` messages remain embedded in the binary and can be located by searching for the `.proto` marker:

```python
PROTO_MARKER = b".proto"

# 1. Find ".proto" suffix in binary data
suffix_position = data.find(PROTO_MARKER, offset)

# 2. Look backwards for 0x0A byte (protobuf string field marker)
marker_start = data.rfind(b"\x0a", offset, suffix_position)

# 3. Decode the length varint
name_length, new_pos = _DecodeVarint(data, marker_start)

# 4. Parse as FileDescriptorProto
descriptor = FileDescriptorProto.FromString(descriptor_data)

# 5. Reconstruct .proto source from descriptor
source_code = to_proto_file(descriptor)
```

The `FileDescriptorProto` contains:
- Package name
- All message definitions (fields, types, numbers)
- Enum definitions
- Extensions
- Import dependencies

### Step 2: Type Mapping Extraction

The TSPRegistry maps numeric type IDs to protobuf message names. This must be extracted at runtime using LLDB:

```python
import lldb

# 1. Create debugger and launch app
debugger = lldb.SBDebugger.Create()
target = debugger.CreateTargetWithFileAndArch(exe_path, None)
target.BreakpointCreateByName("_sendFinishLaunchingNotification")
process = target.LaunchSimple(None, None, os.getcwd())

# 2. Wait for breakpoint
while process.GetState() != lldb.eStateStopped:
    time.sleep(0.1)

# 3. Evaluate TSPRegistry expression
frame = process.GetThreadAtIndex(0).GetFrameAtIndex(0)
registry = frame.EvaluateExpression("[TSPRegistry sharedRegistry]").description

# 4. Parse output: "148 -> 0x102f24680 KN.ChartInfoGeometryCommandArchive"
```

---

## Project Integration

The extraction script is designed to integrate directly with this project's structure.

### Project Structure

```
iwork/
├── proto/                      # Proto definitions (flat)
│   ├── KNArchives.proto        # Keynote messages
│   ├── TNArchives.proto        # Numbers messages
│   ├── TPArchives.proto        # Pages messages
│   ├── TSPMessages.proto       # Shared: Persistence
│   ├── TSKArchives.proto       # Shared: Core
│   ├── TSDArchives.proto       # Shared: Drawing
│   ├── TSTArchives.proto       # Shared: Tables
│   ├── TSWPArchives.proto      # Shared: Word Processing
│   ├── TSCHArchives.proto      # Shared: Charts
│   └── ...
├── proto/KN/                   # Generated Go code
│   └── KNArchives.pb.go
├── proto/TSP/
│   └── TSPMessages.pb.go
├── codegen/
│   ├── Keynote.json            # Type mappings: KN.* messages
│   ├── Pages.json              # Type mappings: TP.* messages
│   ├── Numbers.json            # Type mappings: TN.* messages
│   ├── Common.json             # Type mappings: Shared messages
│   └── codegen.go              # Generates Go decode function
├── index/
│   ├── common.go               # Generated decode functions
│   ├── keynote.go
│   ├── pages.go
│   └── numbers.go
└── scripts/
    └── iwork-proto-extract.sh  # Extraction script
```

### Running the Extraction

```bash
# From the project root, on a Mac with iWork installed:
./scripts/iwork-proto-extract.sh

# Options:
./scripts/iwork-proto-extract.sh --protos-only    # Skip type mappings
./scripts/iwork-proto-extract.sh --mappings-only  # Skip proto extraction
./scripts/iwork-proto-extract.sh --no-codegen     # Skip Go generation
./scripts/iwork-proto-extract.sh --no-cleanup     # Keep temp files
```

### What the Script Does

1. **Extracts proto files** from Keynote.app, Pages.app, Numbers.app
   - Scans binaries for embedded `FileDescriptorProto`
   - Writes to `proto/*.proto` (flat structure)

2. **Extracts type mappings** via LLDB
   - Launches each app briefly
   - Extracts `TSPRegistry sharedRegistry`
   - Splits into `codegen/{Keynote,Pages,Numbers,Common}.json`

3. **Generates Go code** (optional)
   - Runs `protoc` for each package
   - Outputs to `proto/*/`

### Type Mapping Format

The JSON files map numeric type IDs to protobuf message names:

```json
{
  "1": "KN.DocumentArchive",
  "2": "KN.ShowArchive",
  "3": "KN.UIStateArchive",
  ...
}
```

These are split by prefix:
- `KN.*` → `Keynote.json`
- `TP.*` → `Pages.json`
- `TN.*` → `Numbers.json`
- Everything else → `Common.json` (TSP, TSK, TSD, TST, TSWP, TSCH, TSS, TSA, TSCE)

### After Extraction

```bash
# 1. Fix any proto syntax issues
#    (imports, missing dependencies, naming conflicts)

# 2. Regenerate Go code
protoc --proto_path=proto --go_out=proto/TSP --go_opt=paths=source_relative proto/TSPMessages.proto
# ... repeat for other packages

# 3. Generate decode functions
cd codegen
go run codegen.go Common.json > ../index/decode_common.go
go run codegen.go Keynote.json > ../index/decode_keynote.go
# etc.

# 4. Build and test
go build ./...
```

---

## Step-by-Step Guide

### Prerequisites

1. **macOS** with iWork applications installed
2. **Homebrew**: https://brew.sh
3. **Python 3.11+**

### Quick Start (Recommended)

Use the existing `keynote-parser` project which already includes extracted protos:

```bash
# Install
pip install keynote-parser

# Unpack a Keynote file to editable YAML
keynote-parser unpack MyPresentation.key

# Re-pack after editing
keynote-parser pack ./MyPresentation/
```

### Manual Extraction

Use the provided script for fresh extraction:

```bash
# Run the extraction script
./scripts/iwork-proto-extract.sh ./my-iwork-protos

# Or step by step:

# 1. Install dependencies
brew install llvm snappy
pip install "protobuf>=3.20.0,<4" python-snappy rich

# 2. Extract protos (doesn't require launching app)
python3 protodump.py /Applications/Keynote.app ./keynote_protos/

# 3. Extract type mappings (launches app briefly)
python3 extract_mapping.py \
    /Applications/Keynote.app/Contents/MacOS/Keynote \
    keynote_mapping.json
```

### Compiling Extracted Protos

```bash
# Compile to Python
protoc --proto_path=./keynote_protos \
       --python_out=./generated \
       $(find ./keynote_protos -name '*.proto')

# Compile to other languages
protoc --proto_path=./keynote_protos \
       --cpp_out=./generated \
       --java_out=./generated \
       $(find ./keynote_protos -name '*.proto')
```

---

## Dependencies

### System Dependencies

| Package | Purpose | Installation |
|---------|---------|--------------|
| **Homebrew** | Package manager | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| **LLVM** | LLDB with Python bindings | `brew install llvm` |
| **Snappy** | Compression library | `brew install snappy` |

### Python Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `protobuf` | `>=3.20.0,<4` | Parse/generate protobuf |
| `python-snappy` | latest | Snappy compression bindings |
| `rich` | latest | Progress bars (optional) |

Install with:
```bash
pip install "protobuf>=3.20.0,<4" python-snappy rich
```

---

## Troubleshooting

### Type Mapping Extraction Fails

**Symptom**: `extract_mapping.py` errors with "Process exited before breakpoint"

**Cause**: macOS security prevents LLDB from attaching

**Solutions**:

1. **Re-sign the application** (recommended):
   ```bash
   codesign --force --deep --sign - /Applications/Keynote.app
   ```

2. **Disable SIP temporarily** (not recommended for daily use):
   ```bash
   # Boot into Recovery Mode (Cmd+R on Intel, hold power on Apple Silicon)
   # Open Terminal and run:
   csrutil disable
   # Reboot, run extraction, then re-enable:
   csrutil enable
   ```

3. **Use pre-extracted protos** from keynote-parser:
   ```bash
   pip install keynote-parser
   # Protos are at: site-packages/keynote_parser/protos/
   ```

### LLVM Python Version Mismatch

**Symptom**: `ImportError: LLVM Python bindings version mismatch`

**Cause**: LLVM was built with different Python version

**Solution**:
```bash
# Check your Python version
python3 --version

# Reinstall LLVM (will use current Python)
brew reinstall llvm

# Or use matching Python version
# If LLVM has python3.11 bindings, use python3.11
```

### Missing Snappy Headers

**Symptom**: `snappy-c.h not found` during pip install

**Solution**:
```bash
brew install snappy
export CPPFLAGS="-I/opt/homebrew/include"
export LDFLAGS="-L/opt/homebrew/lib"
pip install python-snappy
```

### Protos Have Missing Dependencies

**Symptom**: Some proto files reference imports that weren't extracted

**Cause**: Some internal protos may be embedded differently

**Solution**: The extraction script logs missing dependencies. You may need to:
1. Check if they're Google standard protos (install from google.protobuf)
2. Stub out missing imports if they're unused

---

## Related Projects

| Project | Description | URL |
|---------|-------------|-----|
| **keynote-parser** | Full Keynote parser (Python), actively maintained | https://github.com/psobot/keynote-parser |
| **numbers-parser** | Numbers file parser (Python) | https://github.com/jmcnamara/numbers-parser |
| **iWorkFileFormat** | Original reverse engineering docs | https://github.com/obriensp/iWorkFileFormat |
| **proto-dump** | Original proto extraction tool | https://github.com/obriensp/proto-dump |
| **snzip** | Snappy CLI with iwa support | https://github.com/kubo/snzip |

### keynote-parser Usage

```bash
# Install
pip install keynote-parser

# List files in a Keynote archive
keynote-parser ls MyPresentation.key

# Dump a specific .iwa file as YAML
keynote-parser cat MyPresentation.key /Index/Slide-00001.iwa

# Unpack to editable directory
keynote-parser unpack MyPresentation.key

# Re-pack after editing
keynote-parser pack ./MyPresentation/

# Find and replace text
keynote-parser replace MyPresentation.key \
    --find "old text" \
    --replace "new text"
```

---

## References

### Original Documentation

- [iWork '13 File Format](https://github.com/obriensp/iWorkFileFormat/blob/master/Docs/index.md) by Sean Patrick O'Brien
- [iWork Encrypted Stream](https://github.com/obriensp/iWorkFileFormat/blob/master/Docs/iWork%20Encrypted%20Stream.md)

### Technologies

- [Protocol Buffers](https://developers.google.com/protocol-buffers) - Google's data serialization
- [Snappy](https://github.com/google/snappy) - Google's fast compression
- [Snappy Framing Format](https://github.com/google/snappy/blob/main/framing_format.txt)

### Tools

- [protoc](https://grpc.io/docs/protoc-installation/) - Protocol Buffer compiler
- [protobuf-inspector](https://pypi.org/project/protobuf-inspector/) - Decode unknown protobufs
- [blackboxprotobuf](https://github.com/nccgroup/blackboxprotobuf) - Edit protobufs without schema

---

## Version History

| iWork Version | Notes |
|---------------|-------|
| iWork '13 | Format introduced, documented by O'Brien |
| Keynote 10.x | Protobuf schema changes |
| Keynote 11.x | More schema changes, field renames |
| Keynote 14.4 | Current version supported by keynote-parser |

**Important**: Proto schemas change between iWork versions. Extracted protos are version-specific. The `keynote-parser` project tracks these changes.

---

## Quick Reference

### Decode Raw IWA File

```bash
# 1. Extract Index.zip
unzip -d extracted Document.key/Index.zip

# 2. Decompress .iwa with snzip (if you have it)
snzip -d -t iwa extracted/Index/Document.iwa

# 3. Decode without schema
protoc --decode_raw < Document.iwa.raw

# 4. Or use protobuf-inspector for better output
pip install protobuf-inspector
protobuf_inspector < Document.iwa.raw
```

### Key File Locations in macOS

```
/Applications/Keynote.app/Contents/MacOS/Keynote    # Main binary
/Applications/Pages.app/Contents/MacOS/Pages
/Applications/Numbers.app/Contents/MacOS/Numbers

# Frameworks with additional protos:
/Applications/Keynote.app/Contents/Frameworks/
```

### Common Proto Packages

| Package | Content |
|---------|---------|
| `TSP` | Persistence infrastructure |
| `TSK` | Shared components |
| `TSD` | Drawing/graphics |
| `TST` | Tables |
| `TSWP` | Word processing |
| `TSA` | App-specific |
| `KN` | Keynote-specific |
| `TN` | Numbers-specific |
| `TP` | Pages-specific |
