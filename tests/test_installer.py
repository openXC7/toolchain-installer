"""Offline regression checks; run with python3 -m unittest discover -s tests -v."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "toolchain-sources-builder.sh"
BASH = os.environ.get("BASH_BIN", "bash")


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="openxc7-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def shell(self, code):
        return subprocess.run(
            [BASH, "-eo", "pipefail", "-c", 'source "$1"; ' + code, "test", str(SCRIPT)],
            cwd=self.root,
            env={**os.environ, "INSTALL_PREFIX": str(self.root / "install with spaces"), "JOBS": "2"},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bad_arguments_do_not_install(self):
        for code in ['main typo', 'INSTALL_PREFIX=relative; main', 'JOBS=0; main']:
            with self.subTest(code=code):
                result = self.shell('check_dependencies() { touch unexpected; }; ' + code)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "unexpected").exists())

    def test_linux_dependencies_use_exact_installed_status(self):
        result = self.shell(r'''
            OS=Linux
            APT_DEPENDENCIES=(present removed absent)
            apt-get() { :; }
            dpkg-query() {
                case "$3" in
                    present) echo 'install ok installed' ;;
                    removed) echo 'deinstall ok config-files' ;;
                    absent) return 1 ;;
                esac
            }
            run_as_root() { printf '%s\n' "$*" >> packages; }
            check_dependencies
        ''')
        self.assert_ok(result)
        self.assertEqual((self.root / "packages").read_text().splitlines(),
                         ['apt-get update', 'apt-get install -y removed absent'])

    def test_macos_dependencies_use_brew(self):
        result = self.shell(r'''
            OS=Darwin
            BREW_DEPENDENCIES=(present absent)
            brew() {
                if [[ "$1" == list ]]; then [[ "$3" == present ]];
                else printf '%s\n' "$*" > packages; fi
            }
            check_dependencies
        ''')
        self.assert_ok(result)
        self.assertEqual((self.root / "packages").read_text(), 'install absent\n')

    def test_export_paths_and_venv_precedence(self):
        for os_name in ['Linux', 'Darwin']:
            with self.subTest(os_name=os_name):
                result = self.shell('''
                    OS=%s
                    brew() { echo '/test brew/pypy3'; }
                    mkdir -p "$INSTALL_PREFIX"
                    write_environment
                    export PYTHONPATH=/user/python
                    source "$INSTALL_PREFIX/export.sh"
                    [[ "$PYTHONPATH" == /user/python ]]
                    [[ "$PATH" == "$INSTALL_PREFIX/venv/bin:$INSTALL_PREFIX/bin:"* ]]
                    [[ "$NEXTPNR_XILINX_PYTHON_DIR" == "$INSTALL_PREFIX/lib/python" ]]
                    [[ "$PRJXRAY_DB_DIR" == "$INSTALL_PREFIX/share/nextpnr/prjxray-db" ]]
                ''' % os_name)
                self.assert_ok(result)

    def test_database_install_with_existing_parent(self):
        result = self.shell(r'''
            git init -q db
            echo feature > db/segbits.db
            git -C db add .
            git -C db -c user.name=Test -c user.email=test@example.invalid commit -qm database
            PRJXRAY_DB_HASH=$(git -C db rev-parse HEAD)
            mkdir -p "$INSTALL_PREFIX/share/nextpnr"
            build_prjxray_db db
            build_prjxray_db db
            cmp db/segbits.db "$INSTALL_PREFIX/share/nextpnr/prjxray-db/segbits.db"
            [[ ! -e "$INSTALL_PREFIX/share/nextpnr/prjxray-db/.git" ]]
        ''')
        self.assert_ok(result)

    def test_pinned_checkout_can_be_repeated(self):
        result = self.shell(r'''
            git init -q upstream
            echo source > upstream/source
            git -C upstream add .
            git -C upstream -c user.name=Test -c user.email=test@example.invalid commit -qm source
            revision=$(git -C upstream rev-parse HEAD)
            git clone -q upstream yosys
            git_clone_update yosys "$revision"
            git_clone_update yosys "$revision"
            [[ $(git -C yosys rev-parse HEAD) == "$revision" ]]
        ''')
        self.assert_ok(result)

    def test_nextpnr_reinstall_preserves_database_layout(self):
        result = self.shell(r'''
            OS=Linux
            CMAKE_OPTS=("-DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX")
            git init -q database
            echo bits > database/segbits.db
            git -C database add .
            git -C database -c user.name=Test -c user.email=test@example.invalid commit -qm database
            PRJXRAY_DB_HASH=$(git -C database rev-parse HEAD)
            mkdir -p nextpnr/build nextpnr/xilinx/python nextpnr/xilinx/external
            git clone -q database nextpnr/xilinx/external/prjxray-db
            git init -q nextpnr
            git -C nextpnr update-index --add --cacheinfo "160000,$PRJXRAY_DB_HASH,xilinx/external/prjxray-db"
            git -C nextpnr -c user.name=Test -c user.email=test@example.invalid commit -qm database
            touch nextpnr/build/bbasm nextpnr/xilinx/constids.inc nextpnr/xilinx/python/bbaexport.py
            mkdir -p "$INSTALL_PREFIX/bin" "$INSTALL_PREFIX/lib/python"
            cmake() { :; }
            build_nextpnr nextpnr
            build_nextpnr nextpnr
            [[ ! -e "$INSTALL_PREFIX/lib/external/external" ]]
            cmp database/segbits.db "$INSTALL_PREFIX/lib/external/prjxray-db/segbits.db"
            cmp database/segbits.db "$INSTALL_PREFIX/share/nextpnr/prjxray-db/segbits.db"
            PRJXRAY_DB_HASH=wrong
            if build_nextpnr nextpnr; then exit 1; fi
        ''')
        self.assert_ok(result)

    def test_rerun_resets_submodule_patches_and_build_products(self):
        result = self.shell(r'''
            export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
            commit() { git -C "$1" -c user.name=Test -c user.email=test@example.invalid commit -qm "$2"; }
            git init -q fasm
            echo original > fasm/setup.py
            git -C fasm add .
            commit fasm original
            git init -q upstream
            git -C upstream submodule add -q "$PWD/fasm" third_party/fasm
            commit upstream original
            first=$(git -C upstream rev-parse HEAD)
            echo changed > fasm/setup.py
            git -C fasm add .
            commit fasm changed
            git -C upstream/third_party/fasm pull -q
            git -C upstream add third_party/fasm
            commit upstream changed
            second=$(git -C upstream rev-parse HEAD)
            git clone -q upstream yosys
            git_clone_update yosys "$first"
            # A patched submodule file and a parser library from a previous build.
            echo patched > yosys/third_party/fasm/setup.py
            touch yosys/third_party/fasm/libparse_fasm.so
            clean_repo yosys
            [[ ! -e yosys/third_party/fasm/libparse_fasm.so ]]
            git_clone_update yosys "$second"
            [[ $(cat yosys/third_party/fasm/setup.py) == changed ]]
        ''')
        self.assert_ok(result)

    def test_prjxray_install_removes_legacy_fasm(self):
        result = self.shell(r'''
            lib="$INSTALL_PREFIX/lib/python"
            mkdir -p prjxray "$lib/fasm/parser" "$lib/fasm-0.0.2.post66-py3.14.egg-info"
            touch "$lib/bbaexport.py" "$lib/constids.inc"
            patch_fasm_antlr_build() { :; }
            patch_prjxray_setup() { :; }
            cmake() { :; }
            python3() { :; }
            fasm2frames() { :; }
            build_prjxray prjxray
            [[ ! -e "$lib/fasm" && ! -e "$lib/fasm-0.0.2.post66-py3.14.egg-info" ]]
            [[ -e "$lib/bbaexport.py" && -e "$lib/constids.inc" ]]
        ''')
        self.assert_ok(result)

    def test_fasm_grammar_is_generated_once(self):
        result = self.shell(r'''
            fasm=prjxray/third_party/fasm
            cpp=$fasm/third_party/antlr4/runtime/Cpp
            mkdir -p "$fasm/src" "$cpp/cmake" "$cpp/runtime"
            # Markers of already applied patches, so only the grammar patch runs.
            echo '__hash__ = object.__hash__' > "$fasm/setup.py"
            echo '# ANTLR4_ROOT is the local submodule' > "$cpp/cmake/ExternalAntlr4Cpp.cmake"
            touch "$cpp/CMakeLists.txt"
            echo '-DUTF8_TESTS=OFF' > "$cpp/runtime/CMakeLists.txt"
            printf '%s\n' 'antlr_target(FasmParser antlr/FasmParser.g4 PARSER VISITOR)' \
                '# Include generated files in project environment' \
                'add_library(parse_fasm SHARED ParseFasm.cpp ${ANTLR_FasmParser_CXX_OUTPUTS})' \
                'enable_testing()' > "$fasm/src/CMakeLists.txt"
            cd prjxray
            patch_fasm_antlr_build
            patch_fasm_antlr_build
            cmake=third_party/fasm/src/CMakeLists.txt
            [[ $(grep -c 'add_custom_target(fasm_grammar' "$cmake") == 1 ]]
            [[ $(grep -cE 'add_dependencies\(parse_fasm(_tests|_run)? fasm_grammar\)' "$cmake") == 3 ]]
            grep -A2 'add_custom_target(fasm_grammar' "$cmake" | grep -q '# Include generated files'
        ''')
        self.assert_ok(result)

    def test_failed_build_does_not_install_or_write_environment(self):
        result = self.shell(r'''
            check_dependencies() { :; }
            prepare_python() { :; }
            git_clone_update() { mkdir -p "$1"; }
            clean_repo() { :; }
            cmake() { echo "$*" >> "$INSTALL_PREFIX/cmake-calls"; return 7; }
            OS=Linux
            main yosys
        ''')
        self.assertEqual(result.returncode, 7, result.stderr)
        prefix = self.root / "install with spaces"
        self.assertFalse((prefix / "export.sh").exists())
        self.assertEqual(len((prefix / "cmake-calls").read_text().splitlines()), 1)


if __name__ == '__main__':
    unittest.main()
