#!/bin/bash
# iwork-proto-extract.sh
# Extract Protocol Buffer definitions from Apple iWork applications
# and integrate them into this project's structure.
#
# Requires: macOS with iWork apps installed, Homebrew, Python 3.11+
#
# Usage: ./scripts/iwork-proto-extract.sh
#
# Output:
#   proto/*.proto           - Updated proto definitions
#   codegen/Keynote.json    - Updated type mappings
#   codegen/Pages.json
#   codegen/Numbers.json  
#   codegen/Common.json

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROTO_DIR="$PROJECT_ROOT/proto"
CODEGEN_DIR="$PROJECT_ROOT/codegen"
TEMP_DIR="$PROJECT_ROOT/.iwork-extract-temp"

IWORK_APPS=(
    "/Applications/Keynote.app"
    "/Applications/Pages.app"
    "/Applications/Numbers.app"
)

# Proto package prefixes - used to determine which JSON file a mapping belongs to
KEYNOTE_PREFIXES=("KN.")
PAGES_PREFIXES=("TP.")
NUMBERS_PREFIXES=("TN.")
# Everything else goes to Common.json

# Ensure Go binaries are in PATH
export PATH="$PATH:$(go env GOPATH)/bin"

#=============================================================================
# COLORS
#=============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#=============================================================================
# DEPENDENCY CHECK
#=============================================================================
check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing=()
    
    # Check for macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script requires macOS with iWork applications installed."
        exit 1
    fi
    
    # Check for Homebrew
    if ! command -v brew &> /dev/null; then
        missing+=("homebrew")
    fi
    
    # Check for Python 3
    if ! command -v python3 &> /dev/null; then
        missing+=("python3")
    fi
    
    # Check for protoc
    if ! command -v protoc &> /dev/null; then
        missing+=("protoc")
    fi
    
    # Check for Go
    if ! command -v go &> /dev/null; then
        missing+=("go")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install with:"
        for dep in "${missing[@]}"; do
            case "$dep" in
                homebrew) echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"" ;;
                python3)  echo "  brew install python@3.11" ;;
                protoc)   echo "  brew install protobuf" ;;
                go)       echo "  brew install go" ;;
            esac
        done
        exit 1
    fi
    
    log_success "All dependencies found."
}

install_python_deps() {
    log_info "Installing Python dependencies..."
    pip3 install --quiet "protobuf>=3.20.0,<4" 2>/dev/null || pip3 install "protobuf>=3.20.0,<4"
    log_success "Python dependencies installed."
}

#=============================================================================
# PROTO EXTRACTION SCRIPT (embedded)
#=============================================================================
create_protodump_script() {
    mkdir -p "$TEMP_DIR"
    cat > "$TEMP_DIR/protodump.py" << 'PROTODUMP_EOF'
#!/usr/bin/env python3
"""Extract .proto files from iWork application binaries."""

import logging
import sys
from collections import defaultdict
from pathlib import Path
from typing import List

from google.protobuf import descriptor_pb2
from google.protobuf.descriptor_pool import DescriptorPool
from google.protobuf.internal.decoder import SkipField, _DecodeVarint
from google.protobuf.message import DecodeError

logging.basicConfig(level=logging.INFO, format='%(message)s')

PROTO_TYPES = {
    1: "double", 2: "float", 3: "int64", 4: "uint64", 5: "int32",
    6: "fixed64", 7: "fixed32", 8: "bool", 9: "string", 12: "bytes",
    13: "uint32", 15: "sfixed32", 16: "sfixed64", 17: "sint32", 18: "sint64",
}


def to_proto_file(fds: descriptor_pb2.FileDescriptorSet) -> str:
    """Convert FileDescriptorSet to .proto source code."""
    if len(fds.file) != 1:
        raise NotImplementedError("Only one file per fds.")
    f = fds.file[0]
    lines = ['syntax = "proto2";', ""]

    for dependency in f.dependency:
        lines.append(f'import "{dependency}";')
    if f.dependency:
        lines.append("")

    lines.append(f"package {f.package};")
    lines.append("")

    def generate_enum_lines(f, lines: List[str], indent: int = 0):
        prefix = "  " * indent
        for enum in f.enum_type:
            lines.append(prefix + f"enum {enum.name} " + "{")
            for value in enum.value:
                lines.append(prefix + f"  {value.name} = {value.number};")
            lines.append(prefix + "}")
            lines.append("")

    def generate_field_line(field, in_oneof: bool = False) -> str:
        line = []
        if field.label == 1:
            if not in_oneof:
                line.append("optional")
        elif field.label == 2:
            line.append("required")
        elif field.label == 3:
            line.append("repeated")
        else:
            raise NotImplementedError("Unknown field label type!")

        if field.type in PROTO_TYPES:
            line.append(PROTO_TYPES[field.type])
        elif field.type == 11 or field.type == 14:
            line.append(field.type_name)
        else:
            raise NotImplementedError(f"Unknown field type {field.type}!")

        line.append(field.name)
        line.append("=")
        line.append(str(field.number))
        options = []
        if field.default_value:
            options.append(f"default = {field.default_value}")
        if field.options.deprecated:
            options.append("deprecated = true")
        if field.options.packed:
            options.append("packed = true")
        if options:
            line.append(f"[{', '.join(options)}]")
        return f"{' '.join(line)};"

    def generate_extension_lines(message, lines: List[str], indent: int = 0):
        prefix = "  " * indent
        extensions_grouped_by_extendee = defaultdict(list)
        for extension in message.extension:
            extensions_grouped_by_extendee[extension.extendee].append(extension)
        for extendee, extensions in extensions_grouped_by_extendee.items():
            lines.append(prefix + f"extend {extendee} {{")
            for extension in extensions:
                lines.append(prefix + "  " + generate_field_line(extension))
            lines.append(prefix + "}")
            lines.append("")

    def generate_message_lines(f, lines: List[str], indent: int = 0):
        prefix = "  " * indent
        submessages = f.message_type if hasattr(f, "message_type") else f.nested_type

        for message in submessages:
            lines.append(prefix + f"message {message.name} " + "{")

            generate_enum_lines(message, lines, indent + 1)
            generate_message_lines(message, lines, indent + 1)

            for field in message.field:
                if not field.HasField("oneof_index"):
                    lines.append(prefix + "  " + generate_field_line(field))

            next_prefix = "  " * (indent + 1)
            for oneof_index, oneof in enumerate(message.oneof_decl):
                lines.append(next_prefix + f"oneof {oneof.name} {{")
                for field in message.field:
                    if field.HasField("oneof_index") and field.oneof_index == oneof_index:
                        lines.append(next_prefix + "  " + generate_field_line(field, in_oneof=True))
                lines.append(next_prefix + "}")

            if len(message.extension_range):
                start, end = message.extension_range[0].start, min(message.extension_range[0].end, 536870911)
                lines.append(next_prefix + f"extensions {start} to {end};")

            generate_extension_lines(message, lines, indent + 1)
            lines.append(prefix + "}")
            lines.append("")

    generate_enum_lines(f, lines)
    generate_message_lines(f, lines)
    generate_extension_lines(f, lines)

    return "\n".join(lines)


class ProtoFile:
    def __init__(self, data, pool):
        self.data = data
        self.pool = pool
        self.file_descriptor_proto = descriptor_pb2.FileDescriptorProto.FromString(data)
        self.path = self.file_descriptor_proto.name
        self.package = self.file_descriptor_proto.package
        self.imports = list(self.file_descriptor_proto.dependency)
        self.attempt_to_load()

    def __hash__(self):
        return hash(self.data)

    def __eq__(self, other):
        return isinstance(other, ProtoFile) and self.data == other.data

    def attempt_to_load(self):
        try:
            self.pool.Add(self.file_descriptor_proto)
            return self.pool.FindFileByName(self.path)
        except Exception as e:
            if "duplicate file name" in str(e):
                return self.pool.FindFileByName(e.args[0].split("duplicate file name")[1].strip())
            return None

    @property
    def descriptor(self):
        return self.attempt_to_load()

    @property
    def source(self):
        if self.descriptor:
            fds = descriptor_pb2.FileDescriptorSet()
            fds.file.append(descriptor_pb2.FileDescriptorProto())
            fds.file[0].ParseFromString(self.descriptor.serialized_pb)
            return to_proto_file(fds)
        return None


def read_until_null_tag(data):
    position = 0
    while position < len(data):
        try:
            tag, position = _DecodeVarint(data, position)
        except Exception:
            return position
        if tag == 0:
            return position
        try:
            new_position = SkipField(data, position, len(data), bytes([tag]))
        except (AttributeError, DecodeError):
            return position
        if new_position == -1:
            return position
        position = new_position
    return position


def extract_proto_from_file(filename, descriptor_pool):
    try:
        with open(filename, "rb") as f:
            data = f.read()
    except (IOError, OSError):
        return

    offset = 0
    PROTO_MARKER = b".proto"

    while True:
        suffix_position = data.find(PROTO_MARKER, offset)
        if suffix_position == -1:
            break

        marker_start = data.rfind(b"\x0a", offset, suffix_position)
        if marker_start == -1:
            offset = suffix_position + len(PROTO_MARKER)
            continue

        try:
            name_length, new_pos = _DecodeVarint(data, marker_start)
        except Exception:
            offset = suffix_position + len(PROTO_MARKER)
            continue

        expected_length = 1 + (new_pos - marker_start) + name_length + 7
        current_length = (suffix_position + len(PROTO_MARKER)) - marker_start

        if current_length > expected_length + 30:
            offset = suffix_position + len(PROTO_MARKER)
            continue

        descriptor_length = read_until_null_tag(data[marker_start:]) - 1
        descriptor_data = data[marker_start : marker_start + descriptor_length]
        try:
            proto_file = ProtoFile(descriptor_data, descriptor_pool)
            if proto_file.path.endswith(".proto") and proto_file.path != "google/protobuf/descriptor.proto":
                yield proto_file
        except Exception:
            pass

        offset = marker_start + descriptor_length


def extract_proto_files(input_path: str, output_path: str):
    """Extract proto files and write to output directory."""
    GLOBAL_DESCRIPTOR_POOL = DescriptorPool()

    all_filenames = [str(path) for path in Path(input_path).rglob("*") if not path.is_dir()]
    logging.info(f"Scanning {len(all_filenames):,} files under {input_path}...")

    proto_files_found = set()
    for i, path in enumerate(all_filenames):
        if i % 200 == 0 and i > 0:
            logging.info(f"  Progress: {i}/{len(all_filenames)}")
        for proto in extract_proto_from_file(path, GLOBAL_DESCRIPTOR_POOL):
            proto_files_found.add(proto)

    logging.info(f"Found {len(proto_files_found):,} protobuf definitions.")

    # Write output - flatten to single directory with just filename
    Path(output_path).mkdir(parents=True, exist_ok=True)
    written = 0
    for proto_file in proto_files_found:
        # Use just the filename, not the full path
        filename = Path(proto_file.path).name
        out_path = Path(output_path) / filename
        source = proto_file.source
        if source:
            with open(out_path, "w") as f:
                f.write(source)
            written += 1

    logging.info(f"Wrote {written:,} proto files to {output_path}")
    return written


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input_app_path> <output_dir>")
        sys.exit(1)

    input_path, output_path = sys.argv[1], sys.argv[2]
    extract_proto_files(input_path, output_path)


if __name__ == "__main__":
    main()
PROTODUMP_EOF
}

#=============================================================================
# TYPE MAPPING EXTRACTION SCRIPT (embedded)
#=============================================================================
create_extract_mapping_script() {
    cat > "$TEMP_DIR/extract_mapping.py" << 'MAPPING_EOF'
#!/usr/bin/xcrun python3
"""Extract TSPRegistry type mappings from iWork apps via LLDB."""

import json
import logging
import os
import sys
import time

logging.basicConfig(level=logging.INFO, format='%(message)s')


def find_lldb_python_path():
    llvm_roots = [
        "/opt/homebrew/opt/llvm/libexec",
        "/usr/local/opt/llvm/libexec",
    ]
    
    for llvm_root in llvm_roots:
        if os.path.exists(llvm_root):
            py_version = f"python{sys.version_info.major}.{sys.version_info.minor}"
            lldb_path = f"{llvm_root}/{py_version}/site-packages"
            if os.path.exists(lldb_path):
                return lldb_path
            
            existing = [x for x in os.listdir(llvm_root) if x.startswith("python")]
            raise ImportError(
                f"LLVM Python version mismatch. Found: {', '.join(existing)}, need: {py_version}"
            )
    
    raise ImportError("LLVM not found. Install with: brew install llvm")


def extract_mapping(exe: str) -> dict:
    lldb_path = find_lldb_python_path()
    sys.path.append(lldb_path)
    
    import lldb

    logging.info("Creating LLDB debugger...")
    debugger = lldb.SBDebugger.Create()
    debugger.SetAsync(False)
    
    logging.info(f"Creating target: {exe}")
    target = debugger.CreateTargetWithFileAndArch(exe, None)
    
    if not target:
        raise ValueError(f"Failed to create target for: {exe}")
    
    target.BreakpointCreateByName("_sendFinishLaunchingNotification")
    target.BreakpointCreateByName("_handleAEOpenEvent:")
    target.BreakpointCreateByName("[CKContainer containerWithIdentifier:]")
    target.BreakpointCreateByRegex("___lldb_unnamed_symbol[0-9]+", "CloudKit")

    logging.info("Launching process...")
    process = target.LaunchSimple(None, None, os.getcwd())

    if not process:
        raise ValueError(f"Failed to launch: {exe}. Check code signing.")
    
    try:
        timeout = 30
        start_time = time.time()
        
        while process.GetState() not in (lldb.eStateStopped, lldb.eStateExited):
            if time.time() - start_time > timeout:
                raise TimeoutError("Timed out waiting for breakpoint")
            time.sleep(0.1)

        if process.GetState() == lldb.eStateExited:
            raise ValueError("Process exited before breakpoint. Check code signing.")

        while process.GetState() == lldb.eStateStopped:
            thread = process.GetThreadAtIndex(0)
            
            if thread.GetStopReason() == lldb.eStopReasonBreakpoint:
                frame_str = str(thread.GetSelectedFrame())
                if "CKContainer" in frame_str or "CloudKit" in frame_str:
                    thread.ReturnFromFrame(
                        thread.GetSelectedFrame(),
                        lldb.SBValue().CreateValueFromExpression("0", ""),
                    )
                    process.Continue()
                else:
                    break
            elif thread.GetStopReason() == lldb.eStopReasonException:
                raise RuntimeError(f"LLDB exception: {thread}")
            else:
                process.Continue()

        logging.info("Extracting TSPRegistry...")
        frame = thread.GetFrameAtIndex(0)
        registry = frame.EvaluateExpression("[TSPRegistry sharedRegistry]").description
        
        if not registry or "{" not in registry:
            raise ValueError("Failed to extract TSPRegistry")
        
        content = registry.split("{")[1].split("}")[0]
        lines = [x.strip() for x in content.split("\n") if x.strip()]
        
        # Output as string keys to match existing JSON format
        mapping = {}
        for line in lines:
            if " -> " not in line or "null" in line:
                continue
            parts = line.split(" -> ")
            if len(parts) != 2:
                continue
            type_id = parts[0].strip()  # Keep as string
            message_name = parts[1].split(" ")[-1]
            mapping[type_id] = message_name
        
        logging.info(f"Extracted {len(mapping):,} type mappings.")
        return mapping
        
    finally:
        process.Kill()


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <executable_path> <output.json>")
        sys.exit(1)
    
    exe, output = sys.argv[1], sys.argv[2]
    
    if not os.path.exists(exe):
        print(f"ERROR: Executable not found: {exe}")
        sys.exit(1)
    
    mapping = extract_mapping(exe)
    
    # Sort by numeric value of keys
    sorted_mapping = dict(sorted(mapping.items(), key=lambda x: int(x[0])))
    
    with open(output, "w") as f:
        json.dump(sorted_mapping, f, indent="\t")
    
    logging.info(f"Wrote mapping to {output}")


if __name__ == "__main__":
    main()
MAPPING_EOF
}

#=============================================================================
# MAPPING SPLITTER - Splits combined mapping into per-app JSON files
#=============================================================================
create_mapping_splitter_script() {
    cat > "$TEMP_DIR/split_mappings.py" << 'SPLITTER_EOF'
#!/usr/bin/env python3
"""
Split combined TSPRegistry mappings into per-app JSON files.

This matches the existing project structure:
  - Keynote.json: KN.* messages
  - Pages.json: TP.* messages  
  - Numbers.json: TN.* messages
  - Common.json: Everything else (TSP, TSK, TSS, etc.)
"""

import json
import sys
from pathlib import Path

APP_PREFIXES = {
    "Keynote": ["KN."],
    "Pages": ["TP."],
    "Numbers": ["TN."],
}


def split_mappings(input_files: list, output_dir: str):
    """Merge and split mapping files into per-app JSONs."""
    
    # Merge all input mappings
    combined = {}
    for input_file in input_files:
        with open(input_file) as f:
            data = json.load(f)
            combined.update(data)
    
    # Split into categories
    result = {
        "Keynote": {},
        "Pages": {},
        "Numbers": {},
        "Common": {},
    }
    
    for type_id, message_name in combined.items():
        categorized = False
        for app, prefixes in APP_PREFIXES.items():
            for prefix in prefixes:
                if message_name.startswith(prefix):
                    result[app][type_id] = message_name
                    categorized = True
                    break
            if categorized:
                break
        
        if not categorized:
            result["Common"][type_id] = message_name
    
    # Write output files
    output_path = Path(output_dir)
    for app, mapping in result.items():
        if mapping:  # Only write if there are entries
            # Sort by numeric key
            sorted_mapping = dict(sorted(mapping.items(), key=lambda x: int(x[0])))
            out_file = output_path / f"{app}.json"
            with open(out_file, "w") as f:
                json.dump(sorted_mapping, f, indent="\t")
            print(f"Wrote {len(sorted_mapping)} entries to {out_file}")


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <output_dir> <input1.json> [input2.json ...]")
        sys.exit(1)
    
    output_dir = sys.argv[1]
    input_files = sys.argv[2:]
    
    split_mappings(input_files, output_dir)


if __name__ == "__main__":
    main()
SPLITTER_EOF
}

#=============================================================================
# EXTRACTION FUNCTIONS
#=============================================================================
extract_protos_from_app() {
    local app_path="$1"
    local app_name=$(basename "$app_path" .app)
    local proto_temp="$TEMP_DIR/protos/$app_name"
    
    if [[ ! -d "$app_path" ]]; then
        log_warn "$app_path not found, skipping."
        return 1
    fi
    
    log_info "Extracting protos from $app_name..."
    python3 "$TEMP_DIR/protodump.py" "$app_path" "$proto_temp"
    return 0
}

extract_mapping_from_app() {
    local app_path="$1"
    local app_name=$(basename "$app_path" .app)
    local mapping_file="$TEMP_DIR/mappings/${app_name}_raw.json"
    local exe_path="$app_path/Contents/MacOS/$app_name"
    
    if [[ ! -f "$exe_path" ]]; then
        log_warn "Executable not found: $exe_path"
        return 1
    fi
    
    mkdir -p "$TEMP_DIR/mappings"
    
    log_info "Extracting type mappings from $app_name..."
    log_info "  (This will briefly launch $app_name)"
    
    if python3 "$TEMP_DIR/extract_mapping.py" "$exe_path" "$mapping_file" 2>&1; then
        log_success "Type mapping extraction successful."
        return 0
    else
        log_warn "Type mapping extraction failed."
        log_warn "Try: codesign --force --deep --sign - $app_path"
        return 1
    fi
}

#=============================================================================
# MERGE AND FINALIZE
#=============================================================================
merge_protos() {
    log_info "Merging proto files to $PROTO_DIR..."
    
    # Create backup of existing protos
    if [[ -d "$PROTO_DIR" ]] && [[ "$(ls -A "$PROTO_DIR"/*.proto 2>/dev/null)" ]]; then
        local backup_dir="$PROTO_DIR.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "  Backing up existing protos to $backup_dir"
        cp -r "$PROTO_DIR" "$backup_dir"
    fi
    
    # Find all extracted protos and merge (deduplicating)
    local count=0
    for proto_dir in "$TEMP_DIR/protos/"*/; do
        if [[ -d "$proto_dir" ]]; then
            for proto_file in "$proto_dir"*.proto; do
                if [[ -f "$proto_file" ]]; then
                    local filename=$(basename "$proto_file")
                    cp "$proto_file" "$PROTO_DIR/$filename"
                    ((count++)) || true
                fi
            done
        fi
    done
    
    log_success "Merged $count proto files to $PROTO_DIR"
}

remove_problematic_references() {
    log_info "Removing problematic imports and references..."
    
    for proto_file in "$PROTO_DIR"/*.proto; do
        [[ -f "$proto_file" ]] || continue
        [[ "$proto_file" == *.sos.proto ]] && continue
        
        sed -i '' '/^import ".*\.sos\.proto";/d' "$proto_file"
        
        sed -i '' 's/optional \..*SOS\.[^ ]* [a-z_]* = [0-9]*;/\/\/ REMOVED: SOS field/g' "$proto_file"
        sed -i '' 's/repeated \..*SOS\.[^ ]* [a-z_]* = [0-9]*;/\/\/ REMOVED: SOS field/g' "$proto_file"
        sed -i '' 's/required \..*SOS\.[^ ]* [a-z_]* = [0-9]*;/\/\/ REMOVED: SOS field/g' "$proto_file"
    done
    
    local cmd_proto="$PROTO_DIR/TSCHCommandArchives.proto"
    if [[ -f "$cmd_proto" ]]; then
        sed -i '' 's/optional \.TSCH\.Generated\.[A-Za-z]* [a-z_]* = [0-9]*;/\/\/ REMOVED: GEN field/g' "$cmd_proto"
    fi
    
    local cycle_imports=(
        "TSCHArchives.proto:TSCHPreUFFArchives.proto"
        "TSCHArchives.proto:TSCHArchives.GEN.proto"
        "TSCHArchives.proto:TSCH3DArchives.proto"
        "TSCHCommandArchives.proto:TSCHArchives.GEN.proto"
    )
    
    for entry in "${cycle_imports[@]}"; do
        local file="${entry%%:*}"
        local import="${entry##*:}"
        local proto_file="$PROTO_DIR/$file"
        
        if [[ -f "$proto_file" ]]; then
            sed -i '' "/^import \"${import}\";/d" "$proto_file"
        fi
    done
    
    log_success "Removed problematic imports and references"
}

add_go_package_options() {
    log_info "Adding go_package options to proto files..."
    
    for proto_file in "$PROTO_DIR"/*.proto; do
        [[ -f "$proto_file" ]] || continue
        grep -q "option go_package" "$proto_file" && continue
        
        local pkg_line=$(grep "^package " "$proto_file" | head -1)
        [[ -z "$pkg_line" ]] && continue
        local pkg_name=$(echo "$pkg_line" | sed 's/package //;s/;//')
        
        local go_pkg_path
        case "$pkg_name" in
            TSCH.Generated)
                go_pkg_path="TSCH"
                ;;
            TSCH.PreUFF)
                go_pkg_path="TSCH/PreUFF"
                ;;
            *)
                go_pkg_path=$(echo "$pkg_name" | tr '.' '/')
                ;;
        esac
        
        local go_pkg="github.com/dunhamsteve/iwork/proto/${go_pkg_path}"
        sed -i '' "/^package ${pkg_name};/a\\
option go_package = \"${go_pkg}\";" "$proto_file"
    done
    
    log_success "Added go_package options"
}

merge_mappings() {
    log_info "Merging type mappings to $CODEGEN_DIR..."
    
    # Find all raw mapping files
    local mapping_files=()
    for f in "$TEMP_DIR/mappings/"*_raw.json; do
        if [[ -f "$f" ]]; then
            mapping_files+=("$f")
        fi
    done
    
    if [[ ${#mapping_files[@]} -eq 0 ]]; then
        log_warn "No mapping files found. Type mappings not updated."
        return 1
    fi
    
    # Split into per-app JSONs
    python3 "$TEMP_DIR/split_mappings.py" "$CODEGEN_DIR" "${mapping_files[@]}"
    
    log_success "Type mappings updated in $CODEGEN_DIR"
}

#=============================================================================
# GO CODE GENERATION
#=============================================================================
generate_go_code() {
    log_info "Generating Go code from protos..."
    
    if ! command -v protoc-gen-go &> /dev/null; then
        log_info "  Installing protoc-gen-go..."
        go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
    fi
    
    cd "$PROJECT_ROOT"
    
    local packages=("TSP" "TSK" "TSS" "TSA" "TSD" "TSCE" "TSCH" "TST" "TSWP" "KN" "TN" "TP" "TSCK")
    
    for pkg in "${packages[@]}"; do
        mkdir -p "$PROTO_DIR/$pkg"
    done
    mkdir -p "$PROTO_DIR/TSCH/PreUFF"
    
    log_info "  Compiling proto files..."
    
    local proto_files=()
    for f in "$PROTO_DIR"/*.proto; do
        [[ -f "$f" ]] || continue
        local fname=$(basename "$f")
        case "$fname" in
            *.sos.proto|TSCHArchives.GEN.proto)
                continue
                ;;
        esac
        proto_files+=("$f")
    done
    
    if [[ ${#proto_files[@]} -eq 0 ]]; then
        log_warn "No proto files found in $PROTO_DIR"
        return 1
    fi
    
    protoc --proto_path="$PROTO_DIR" \
           --go_out="$PROTO_DIR" \
           --go_opt=module=github.com/dunhamsteve/iwork/proto \
           "${proto_files[@]}" 2>&1 | while read -r line; do
        if [[ -n "$line" ]]; then
            log_warn "  protoc: $line"
        fi
    done
    
    local generated=0
    for pkg in "${packages[@]}"; do
        local pb_count=$(find "$PROTO_DIR/$pkg" -name "*.pb.go" 2>/dev/null | wc -l)
        if [[ $pb_count -gt 0 ]]; then
            log_info "  Generated $pb_count file(s) in $pkg/"
            ((generated += pb_count))
        fi
    done
    local preuff_count=$(find "$PROTO_DIR/TSCH/PreUFF" -name "*.pb.go" 2>/dev/null | wc -l)
    if [[ $preuff_count -gt 0 ]]; then
        log_info "  Generated $preuff_count file(s) in TSCH/PreUFF/"
        ((generated += preuff_count))
    fi
    
    if [[ $generated -eq 0 ]]; then
        log_warn "No Go files were generated. Check proto files for errors."
        return 1
    fi
    
    log_success "Go code generation complete ($generated files)."
}

run_codegen() {
    log_info "Running codegen to generate decode functions..."
    
    cd "$PROJECT_ROOT/codegen"
    
    # The existing codegen expects a single JSON file, we need to merge
    # For now, just inform the user
    log_info "  Run: cd codegen && go run codegen.go Common.json > ../index/decode_common.go"
    log_info "  (Repeat for Keynote.json, Pages.json, Numbers.json)"
    
    log_success "See above for codegen commands."
}

#=============================================================================
# CLEANUP
#=============================================================================
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        log_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

#=============================================================================
# HELP
#=============================================================================
show_help() {
    cat << EOF
iWork Protocol Buffer Extraction Script
========================================

Extracts Protocol Buffer definitions from Apple iWork applications
and integrates them into this project's structure.

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -h, --help        Show this help message
    --protos-only     Only extract proto files (skip type mappings)
    --mappings-only   Only extract type mappings (skip protos)
    --no-cleanup      Don't remove temporary files
    --no-codegen      Skip Go code generation
    --keep-protos     Keep existing proto/*.proto files (only update mappings and extract new protos to temp)

REQUIREMENTS:
    - macOS with iWork applications installed (Keynote, Pages, Numbers)
    - Homebrew, Python 3.11+, protoc, Go

OUTPUT:
    proto/*.proto           Updated proto definitions
    proto/*/                Generated Go code (*.pb.go)
    codegen/Keynote.json    Type mappings for Keynote
    codegen/Pages.json      Type mappings for Pages
    codegen/Numbers.json    Type mappings for Numbers
    codegen/Common.json     Shared type mappings

TROUBLESHOOTING:
    If type mapping extraction fails, re-sign the apps:
    codesign --force --deep --sign - /Applications/Keynote.app
    codesign --force --deep --sign - /Applications/Pages.app
    codesign --force --deep --sign - /Applications/Numbers.app

EOF
    exit 0
}

#=============================================================================
# MAIN
#=============================================================================
main() {
    local protos_only=false
    local mappings_only=false
    local no_cleanup=false
    local no_codegen=false
    local keep_protos=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help ;;
            --protos-only) protos_only=true ;;
            --mappings-only) mappings_only=true ;;
            --no-cleanup) no_cleanup=true ;;
            --no-codegen) no_codegen=true ;;
            --keep-protos) keep_protos=true; no_codegen=true ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done
    
    echo "========================================"
    echo "iWork Protocol Buffer Extraction"
    echo "========================================"
    echo ""
    echo "Project root: $PROJECT_ROOT"
    echo ""
    
    # Setup
    check_dependencies
    install_python_deps
    
    mkdir -p "$TEMP_DIR"
    create_protodump_script
    create_extract_mapping_script
    create_mapping_splitter_script
    
    # Extract from each app
    local extracted_protos=false
    local extracted_mappings=false
    
    for app in "${IWORK_APPS[@]}"; do
        echo ""
        log_info "=== Processing $(basename "$app" .app) ==="
        
        if [[ "$mappings_only" != "true" ]]; then
            if extract_protos_from_app "$app"; then
                extracted_protos=true
            fi
        fi
        
        if [[ "$protos_only" != "true" ]]; then
            if extract_mapping_from_app "$app"; then
                extracted_mappings=true
            fi
        fi
    done
    
    # Merge results
    echo ""
    log_info "=== Finalizing ==="
    
    if [[ "$extracted_protos" == "true" ]] && [[ "$keep_protos" != "true" ]]; then
        merge_protos
        remove_problematic_references
        add_go_package_options
    elif [[ "$extracted_protos" == "true" ]]; then
        log_info "Keeping existing proto files. New protos extracted to: $TEMP_DIR/protos/"
        log_info "  Compare manually and merge changes as needed."
        no_cleanup=true
    fi
    
    if [[ "$extracted_mappings" == "true" ]]; then
        merge_mappings
    fi
    
    # Generate Go code
    if [[ "$no_codegen" != "true" ]] && [[ "$extracted_protos" == "true" ]]; then
        echo ""
        generate_go_code
        run_codegen
    fi
    
    # Cleanup
    if [[ "$no_cleanup" != "true" ]]; then
        cleanup
    fi
    
    echo ""
    echo "========================================"
    echo "EXTRACTION COMPLETE"
    echo "========================================"
    echo ""
    echo "Next steps:"
    echo "  1. Review updated proto files in $PROTO_DIR"
    echo "  2. Fix any proto compilation errors"
    echo "  3. Run: cd codegen && go run codegen.go Common.json"
    echo "  4. Test with: go build ./..."
}

main "$@"
