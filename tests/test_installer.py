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
                    [[ "$NEXTPNR_XILINX_DIR" == "$INSTALL_PREFIX" ]]
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
            mkdir -p nextpnr/build/bba nextpnr/himbaechel/uarch/xilinx/gen \
                     nextpnr/himbaechel/uarch/xilinx/meta nextpnr/himbaechel/himbaechel_dbgen \
                     nextpnr/.github/scripts
            printf '#!/bin/sh\n' > nextpnr/.github/scripts/nextpnr-xilinx-shim.sh
            touch nextpnr/build/bba/bbasm nextpnr/himbaechel/uarch/xilinx/constids.inc
            touch nextpnr/himbaechel/uarch/xilinx/gen/xilinx_gen.py
            mkdir -p "$INSTALL_PREFIX/bin" "$INSTALL_PREFIX/lib"
            cmake() { :; }
            build_nextpnr nextpnr "$PWD/database"
            build_nextpnr nextpnr "$PWD/database"
            cmp database/segbits.db "$INSTALL_PREFIX/share/nextpnr/prjxray-db/segbits.db"
            [[ ! -e "$INSTALL_PREFIX/share/nextpnr/prjxray-db/.git" ]]
            [[ -x "$INSTALL_PREFIX/bin/nextpnr-xilinx" ]]
            [[ -e "$INSTALL_PREFIX/share/nextpnr/himbaechel/uarch/xilinx/gen/xilinx_gen.py" ]]
            [[ -e "$INSTALL_PREFIX/share/nextpnr/himbaechel/himbaechel_dbgen" ]]
            [[ -e "$INSTALL_PREFIX/lib/constids.inc" ]]
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
            touch "$lib/constids.inc"
            patch_fasm_antlr_build() { :; }
            patch_prjxray_setup() { :; }
            cmake() { :; }
            python3() { :; }
            fasm2frames() { :; }
            build_prjxray prjxray
            [[ ! -e "$lib/fasm" && ! -e "$lib/fasm-0.0.2.post66-py3.14.egg-info" ]]
            [[ -e "$lib/constids.inc" ]]
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

    def test_prjxray_packages_are_installed_without_the_build_directory(self):
        """The prefix must not import from the build directory or from $HOME.

        Editable installs leave the virtual environment pointing at the prjxray
        checkout, so an installation shared between users or machines only works
        where that checkout is readable; see openXC7/toolchain-installer#10.
        """
        result = self.shell(r'''
            mkdir -p "$INSTALL_PREFIX" prjxray/third_party/fasm prjxray/third_party/python-sdf-timing
            printf '%s\n' intervaltree numpy '' '# Third party' \
                '-e third_party/fasm' '-e third_party/python-sdf-timing' '-e .' \
                > prjxray/requirements.txt
            patch_fasm_antlr_build() { :; }
            patch_prjxray_setup() { :; }
            cmake() { :; }
            fasm2frames() { :; }
            python3() {
                echo "$*" >> "$INSTALL_PREFIX/python3-calls"
                for arg in "$@"; do
                    if [[ "$arg" == requirements-installer.txt ]]; then
                        cp "$arg" "$INSTALL_PREFIX/plain-requirements"
                    fi
                done
            }
            build_prjxray prjxray
            calls="$INSTALL_PREFIX/python3-calls"
            # The local packages are installed as ordinary directories, not as
            # editable ones, and never into a per-user location.
            grep -q -- '-m pip install third_party/fasm third_party/python-sdf-timing \.' "$calls"
            ! grep -q -- '-e ' "$calls"
            ! grep -q -- '--user' "$calls"
            ! grep -q -- '--target' "$calls"
            # The requirements file handed to pip no longer lists editable paths,
            # while upstream's still does.
            grep -q intervaltree "$INSTALL_PREFIX/plain-requirements"
            ! grep -qE '^[[:space:]]*-e[[:space:]]' "$INSTALL_PREFIX/plain-requirements"
            grep -qE '^[[:space:]]*-e[[:space:]]' prjxray/requirements.txt
            [[ ! -e prjxray/requirements-installer.txt ]]
        ''')
        self.assert_ok(result)

    def test_prjxray_requirements_with_only_editable_entries(self):
        """An empty non-editable list must not abort the install under set -e."""
        result = self.shell(r'''
            mkdir -p "$INSTALL_PREFIX" prjxray/third_party/fasm prjxray/third_party/python-sdf-timing
            printf '%s\n' \
                '-e third_party/fasm' '-e third_party/python-sdf-timing' '-e .' \
                > prjxray/requirements.txt
            patch_fasm_antlr_build() { :; }
            patch_prjxray_setup() { :; }
            cmake() { :; }
            fasm2frames() { :; }
            python3() { echo "$*" >> "$INSTALL_PREFIX/python3-calls"; }
            build_prjxray prjxray
            # The local packages are still installed, and the temporary
            # requirements file is removed again.
            grep -q -- '-m pip install third_party/fasm third_party/python-sdf-timing \.' "$INSTALL_PREFIX/python3-calls"
            [[ ! -e prjxray/requirements-installer.txt ]]
        ''')
        self.assert_ok(result)

    def test_prjxray_install_removes_stale_editable_finders(self):
        result = self.shell(r'''
            sp="$INSTALL_PREFIX/venv/lib/python3.9/site-packages"
            mkdir -p prjxray "$sp/__pycache__"
            printf '%s\n' intervaltree > prjxray/requirements.txt
            touch "$sp/__editable__.prjxray-0.0.1.pth" \
                "$sp/__editable___prjxray_0_0_1_finder.py" \
                "$sp/__editable___fasm_0_0_2_post66_finder.py" \
                "$sp/__pycache__/__editable___prjxray_0_0_1_finder.cpython-39.pyc" \
                "$sp/unrelated.pth"
            patch_fasm_antlr_build() { :; }
            patch_prjxray_setup() { :; }
            cmake() { :; }
            python3() { :; }
            fasm2frames() { :; }
            build_prjxray prjxray
            [[ ! -e "$sp/__editable__.prjxray-0.0.1.pth" ]]
            [[ ! -e "$sp/__editable___prjxray_0_0_1_finder.py" ]]
            [[ ! -e "$sp/__editable___fasm_0_0_2_post66_finder.py" ]]
            [[ ! -e "$sp/__pycache__/__editable___prjxray_0_0_1_finder.cpython-39.pyc" ]]
            [[ -e "$sp/unrelated.pth" ]]
        ''')
        self.assert_ok(result)


    def test_bazel_download_is_verified_and_idempotent(self):
        """The pinned binary is checked against the published digest, once."""
        result = self.shell(r'''
            OS=Linux
            uname() { echo x86_64; }
            curl() {
                while [[ $# > 0 ]]; do
                    if [[ "$1" == -o ]]; then
                        shift
                        printf '#!/bin/sh\necho "bazel %s"\n' "$BAZEL_VERSION" > "$1"
                        printf '%s\n' "${BAZEL_VERSION}" >> downloads
                        return 0
                    fi
                    shift
                done
                return 1
            }
            # The digest install_bazel() expects for Linux/x86_64.
            sha256sum() { echo "18255229d933b8da10151bdef223a302744296b09af8af1988c93faa1ea3c71f  file"; }
            install_bazel
            [[ -x "$INSTALL_PREFIX/bin/bazel" ]]
            [[ $("$INSTALL_PREFIX/bin/bazel" --version) == 'bazel 8.5.0' ]]
            [[ $(wc -l < downloads) == 1 ]]
            # A rerun with the same pin must not download again.
            install_bazel
            [[ $(wc -l < downloads) == 1 ]]
            # A different pin replaces the installed version instead of reusing it.
            BAZEL_VERSION=9.9.9
            install_bazel
            [[ $(wc -l < downloads) == 2 ]]
            [[ $("$INSTALL_PREFIX/bin/bazel" --version) == 'bazel 9.9.9' ]]
        ''')
        self.assert_ok(result)

    def test_bazel_checksum_mismatch_installs_nothing(self):
        result = self.shell(r'''
            OS=Linux
            uname() { echo x86_64; }
            curl() {
                while [[ $# > 0 ]]; do
                    if [[ "$1" == -o ]]; then shift; printf 'tampered\n' > "$1"; return 0; fi
                    shift
                done
                return 1
            }
            sha256sum() { echo "0000  file"; }
            install_bazel
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stdout + result.stderr)
        self.assertFalse((self.root / "install with spaces" / "bin" / "bazel").exists())

    def test_fpga_as_is_built_with_the_prefix_bazel(self):
        """build_fpga_as() must call the Bazel it installed into the prefix."""
        result = self.shell(r'''
            mkdir -p fpga-assembler
            # The script invokes Bazel by absolute path, so the stand-in has to
            # be a program at that path rather than a shell function.
            install_bazel() {
                mkdir -p "$INSTALL_PREFIX/bin"
                cat > "$INSTALL_PREFIX/bin/bazel" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> bazel-args
mkdir -p bazel-bin/fpga
printf '#!/bin/sh\necho fpga-as\n' > bazel-bin/fpga/fpga-as
MOCK
                chmod 755 "$INSTALL_PREFIX/bin/bazel"
            }
            install() { printf '%s\n' "$*" >> installs; cp "${@: -2:1}" "${@: -1}"; chmod 755 "${@: -1}"; }
            build_fpga_as fpga-assembler
            grep -q -- '//fpga:fpga-as' fpga-assembler/bazel-args
            grep -q -- '-c opt' fpga-assembler/bazel-args
            grep -q -- '-m755 -s' fpga-assembler/installs
            [[ -x "$INSTALL_PREFIX/bin/fpga-as" ]]
        ''')
        self.assert_ok(result)


if __name__ == '__main__':
    unittest.main()
