#!/usr/bin/env bash

# Used to pick a package manager and for a few macOS-specific workarounds.
OS="$(uname -s)"

# Some vendored third-party CMake projects (googletest, antlr4) declare a
# cmake_minimum_required too old for current CMake to configure by default.
# This lets it configure them anyway. See patch_fasm_antlr_build().
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# Override these for a separate installation or a memory-limited build host.
INSTALL_PREFIX=${INSTALL_PREFIX:-/opt/openxc7}

# Python packages are installed into the toolchain venv, not the system Python.
# Do not use the distro ANTLR runtime: FASM needs its vendored version.
APT_DEPENDENCIES=(build-essential git ca-certificates cmake pkg-config bison flex gawk
    python3 python3-dev python3-venv default-jre-headless uuid-dev
    libboost-filesystem-dev libboost-iostreams-dev libboost-thread-dev
    libboost-program-options-dev libboost-python-dev libeigen3-dev
    libreadline-dev zlib1g-dev tcl-dev
    libffi-dev graphviz xdot pypy3)
BREW_DEPENDENCIES=(cmake git python openjdk pypy3 boost boost-python3 eigen
    bison flex gawk pkg-config tcl-tk readline libffi zlib graphviz xdot llvm libomp)

# Tools commit hash.
# Yosys
YOSYS_HASH=v0.69

NEXTPNR_XILINX_HASH=cbabb651
# Pin the recent source previously fetched from master. Tag 0.9.2 predates
# the HP-bank glue and tile-alias fixes needed by the current database.
PRJXRAY_HASH=ed3331c6200f421164101388759fc2860b0f5634
# Match NEXTPNR_XILINX_HASH's xilinx/external/prjxray-db submodule
PRJXRAY_DB_HASH=a90f27c1caefee5276f47440f4c730b50519a86f

# Portable "number of cpus" helper (macOS has no nproc by default).
get_nproc() {
	if [[ -n "${JOBS:-}" ]]; then
		echo "$JOBS"
	elif command -v nproc >/dev/null 2>&1; then
		nproc
	elif [[ "$OS" == "Darwin" ]] && command -v sysctl >/dev/null 2>&1; then
		sysctl -n hw.ncpu
	else
		getconf _NPROCESSORS_ONLN
	fi
}

# Use one interpreter for pip, Cython, FASM and the installed console scripts.
prepare_python() {
	python3 -m venv "$INSTALL_PREFIX/venv"
	export PATH="$INSTALL_PREFIX/venv/bin:$PATH"
	# An already sourced export.sh must not pull an old FASM into this build.
	unset PYTHONPATH
	python3 -m pip install --upgrade pip
	python3 -m pip install setuptools wheel cython
	# Yosys 0.68 needs CMake 3.28; e.g. Ubuntu 22.04 ships an older version.
	if ! python3 -c 'import subprocess, sys; v = subprocess.check_output(["cmake", "--version"], text=True).split()[2]; sys.exit(tuple(map(int, v.split(".")[:2])) < (3, 28))'; then
		python3 -m pip install 'cmake>=3.28'
	fi
}

# fasm's fast ANTLR-based C++ parser fails to build without these fixes and
# silently falls back to a much slower pure-Python one, on any platform.
# Called from build_prjxray() before its pip install.
# Idempotent: patches files in a git submodule that may get re-checked-out.
patch_fasm_antlr_build() {
	local fasm_dir="third_party/fasm"
	local setup_py="$fasm_dir/setup.py"
	local antlr_root="$fasm_dir/third_party/antlr4/runtime/Cpp"

	# 1. setuptools' Extension defines __eq__ without __hash__, making
	#    instances unhashable - but AntlrCMakeBuild uses them as dict keys.
	#    "TypeError: cannot use 'CMakeExtension' as a dict key".
	if ! grep -q "__hash__ = object.__hash__" "$setup_py"; then
		python3 - "$setup_py" <<-'PYEOF'
			import sys
			path = sys.argv[1]
			with open(path) as f:
			    content = f.read()
			marker = "class CMakeExtension(Extension):\n"
			assert content.count(marker) == 1, f"expected exactly one {marker!r} in {path}"
			patched = content.replace(
			    marker,
			    marker
			    + "    # Extension defines __eq__ without __hash__, making instances\n"
			      "    # unhashable by default; AntlrCMakeBuild below needs them as dict\n"
			      "    # keys. Restore identity-based hashing.\n"
			      "    __hash__ = object.__hash__\n\n",
			    1,
			)
			with open(path, "w") as f:
			    f.write(patched)
			PYEOF
	fi

	# 2. Build antlr4's C++ runtime from the local submodule, not by
	#    fetching "master" from GitHub: the generated parser code is only
	#    ABI-compatible with the exact ANTLR version it was generated from
	#    (the bundled jar), and "master" (or any system antlr4-runtime) is
	#    always a different, incompatible version.
	local ext_cmake="$antlr_root/cmake/ExternalAntlr4Cpp.cmake"
	if ! grep -q "ANTLR4_ROOT is the local submodule" "$ext_cmake"; then
		python3 - "$ext_cmake" <<-'PYEOF'
			import sys
			path = sys.argv[1]
			with open(path) as f:
			    content = f.read()

			old_root = """set(ANTLR4_ROOT ${CMAKE_CURRENT_BINARY_DIR}/antlr4_runtime/src/antlr4_runtime)
			set(ANTLR4_INCLUDE_DIRS ${ANTLR4_ROOT}/runtime/Cpp/runtime/src)
			set(ANTLR4_GIT_REPOSITORY https://github.com/antlr/antlr4.git)
			if(NOT DEFINED ANTLR4_TAG)
			  # Set to branch name to keep library updated at the cost of needing to rebuild after 'clean'
			  # Set to commit hash to keep the build stable and does not need to rebuild after 'clean'
			  set(ANTLR4_TAG master)
			endif()
			"""
			new_root = """# Local submodule, already at the version matching the bundled ANTLR
			# jar, instead of fetching "master" (see patch_fasm_antlr_build()).
			set(ANTLR4_ROOT ${CMAKE_CURRENT_LIST_DIR}/../../..)
			set(ANTLR4_INCLUDE_DIRS ${ANTLR4_ROOT}/runtime/Cpp/runtime/src)
			"""
			assert old_root in content, "ExternalAntlr4Cpp.cmake ANTLR4_ROOT block not found (upstream changed?)"
			content = content.replace(old_root, new_root, 1)

			old_ep = """if(ANTLR4_ZIP_REPOSITORY)
			  ExternalProject_Add(
			      antlr4_runtime
			      PREFIX antlr4_runtime
			      URL ${ANTLR4_ZIP_REPOSITORY}
			      DOWNLOAD_DIR ${CMAKE_CURRENT_BINARY_DIR}
			      BUILD_COMMAND ""
			      BUILD_IN_SOURCE 1
			      SOURCE_DIR ${ANTLR4_ROOT}
			      SOURCE_SUBDIR runtime/Cpp
			      CMAKE_CACHE_ARGS
			          -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
			          -DWITH_STATIC_CRT:BOOL=${ANTLR4_WITH_STATIC_CRT}
			      INSTALL_COMMAND ""
			      EXCLUDE_FROM_ALL 1)
			else()
			  ExternalProject_Add(
			      antlr4_runtime
			      PREFIX antlr4_runtime
			      GIT_REPOSITORY ${ANTLR4_GIT_REPOSITORY}
			      GIT_TAG ${ANTLR4_TAG}
			      DOWNLOAD_DIR ${CMAKE_CURRENT_BINARY_DIR}
			      BUILD_COMMAND ""
			      BUILD_IN_SOURCE 1
			      SOURCE_DIR ${ANTLR4_ROOT}
			      SOURCE_SUBDIR runtime/Cpp
			      CMAKE_CACHE_ARGS
			          -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
			          -DWITH_STATIC_CRT:BOOL=${ANTLR4_WITH_STATIC_CRT}
			      INSTALL_COMMAND ""
			      EXCLUDE_FROM_ALL 1)
			endif()"""
			new_ep = """# ANTLR4_ROOT is the local submodule, already checked out at the right
			# version - nothing to download.
			ExternalProject_Add(
			    antlr4_runtime
			    PREFIX antlr4_runtime
			    DOWNLOAD_COMMAND ""
			    BUILD_COMMAND ""
			    BUILD_IN_SOURCE 1
			    SOURCE_DIR ${ANTLR4_ROOT}
			    SOURCE_SUBDIR runtime/Cpp
			    CMAKE_CACHE_ARGS
			        -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
			        -DWITH_STATIC_CRT:BOOL=${ANTLR4_WITH_STATIC_CRT}
			    INSTALL_COMMAND ""
			    EXCLUDE_FROM_ALL 1)"""
			assert old_ep in content, "ExternalAntlr4Cpp.cmake ExternalProject_Add block not found (upstream changed?)"
			content = content.replace(old_ep, new_ep, 1)

			with open(path, "w") as f:
			    f.write(content)
			PYEOF
	fi

	# 3. Its CMakeLists.txt pins some CMake policies to OLD; that behavior
	#    is gone in modern CMake, making it a hard configure error. Naturally
	#    idempotent: no-op once already NEW.
	sed -i.bak -E 's/CMAKE_POLICY\(SET (CMP0054|CMP0045|CMP0042|CMP0059) OLD\)/CMAKE_POLICY(SET \1 NEW)/' \
		"$antlr_root/CMakeLists.txt"
	rm -f "$antlr_root/CMakeLists.txt.bak"

	# 4. GitHub no longer serves the unauthenticated git:// protocol, so
	#    fetching its utfcpp dependency over it always fails.
	sed -i.bak 's#git://github.com/nemtrif/utfcpp#https://github.com/nemtrif/utfcpp.git#' \
		"$antlr_root/runtime/CMakeLists.txt"
	rm -f "$antlr_root/runtime/CMakeLists.txt.bak"

	# 5. We need UTFCPP's headers, not its tests/samples. Its bundled old
	#    googletest fails under GCC 13 (-Werror=maybe-uninitialized), causing
	#    the entire ANTLR build to fall back to textX. FASM's own tests remain.
	if ! grep -q -- '-DUTF8_TESTS=OFF' "$antlr_root/runtime/CMakeLists.txt"; then
		python3 - "$antlr_root/runtime/CMakeLists.txt" <<-'PYEOF'
			import sys
			path = sys.argv[1]
			with open(path) as f:
			    content = f.read()
			old = '-Dgtest_force_shared_crt=ON'
			assert content.count(old) == 1, "UTFCPP CMake arguments changed"
			content = content.replace(old, '-DUTF8_TESTS=OFF -DUTF8_SAMPLES=OFF')
			old = 'TEST_AFTER_INSTALL    1'
			assert content.count(old) == 1, "UTFCPP test step changed"
			content = content.replace(old, 'TEST_COMMAND          ""')
			with open(path, "w") as f:
			    f.write(content)
			PYEOF
	fi

	# 6. parse_fasm, parse_fasm_tests and parse_fasm_run each list the generated
	#    grammar sources, so a parallel build runs ANTLR once per target at the
	#    same time and can compile a half-written FasmParser.cpp (undefined
	#    references at link time). Generate it once, in a target they depend on.
	if ! grep -q fasm_grammar "$fasm_dir/src/CMakeLists.txt"; then
		python3 - "$fasm_dir/src/CMakeLists.txt" <<-'PYEOF'
			import sys
			path = sys.argv[1]
			with open(path) as f:
			    content = f.read()
			marker = "# Include generated files in project environment\n"
			assert content.count(marker) == 1, "FASM grammar targets changed"
			grammar = "add_custom_target(fasm_grammar DEPENDS ${ANTLR_FasmLexer_CXX_OUTPUTS} ${ANTLR_FasmParser_CXX_OUTPUTS})\n\n"
			content = content.replace(marker, grammar + marker, 1)
			for target in ("parse_fasm", "parse_fasm_tests", "parse_fasm_run"):
			    content += "add_dependencies(%s fasm_grammar)\n" % target
			with open(path, "w") as f:
			    f.write(content)
			PYEOF
	fi
}

run_as_root() {
	if [[ $(id -u) == 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

check_dependencies() {
	local package
	local missing=()
	case "$OS" in
	Darwin)
		if ! command -v brew >/dev/null 2>&1; then
			echo "Error: install Homebrew from https://brew.sh first." >&2
			return 1
		fi
		for package in "${BREW_DEPENDENCIES[@]}"; do
			if ! brew list --versions "$package" >/dev/null 2>&1; then
				missing+=("$package")
			fi
		done
		if [[ ${#missing[@]} != 0 ]]; then
			brew install "${missing[@]}"
		fi
		;;
	Linux)
		if ! command -v apt-get >/dev/null 2>&1; then
			echo "Error: automatic Linux dependency installation requires Debian/Ubuntu (apt-get)." >&2
			return 1
		fi
		for package in "${APT_DEPENDENCIES[@]}"; do
			if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) != 'install ok installed' ]]; then
				missing+=("$package")
			fi
		done
		if [[ ${#missing[@]} != 0 ]]; then
			run_as_root apt-get update
			run_as_root apt-get install -y "${missing[@]}"
		fi
		;;
	*)
		echo "Error: unsupported operating system: $OS" >&2
		return 1
		;;
	esac
}

git_clone_update() (
	local repo=$1 repo_hash=$2 repo_url
	case "$repo" in
		yosys) repo_url=https://github.com/YosysHQ/yosys.git ;;
		nextpnr-xilinx|prjxray|prjxray-db) repo_url="https://github.com/openXC7/$repo.git" ;;
		*) echo "Error: unknown repo $repo" >&2; return 1 ;;
	esac
	if [[ ! -d "$repo" ]]; then
		git clone "$repo_url" "$repo"
	fi
	cd "$repo"
	# Pinned checkouts have detached HEADs; git pull fails on the second run.
	git fetch origin --tags
	git checkout -- .
	git checkout --detach "$repo_hash"
	# --force discards local changes in submodules, such as the FASM patches of
	# a previous run, which would otherwise block a changed submodule pin.
	# build_prjxray() reapplies the patches.
	git submodule update --init --recursive --force
)

# prjxray's setup.py declares packages=['prjxray'], omitting the sibling
# `utils` package that its fasm2frames entry point needs - modern pip's
# editable installs expose only declared packages, so the installed
# `fasm2frames` fails with "ModuleNotFoundError: No module named 'utils'".
# Idempotent; run from inside the prjxray repo, before build_prjxray()
# installs it.
patch_prjxray_setup() {
	local setup_py="setup.py"
	if ! grep -q "packages=\['prjxray', 'utils'\]" "$setup_py"; then
		sed -i.bak "s/packages=\['prjxray'\]/packages=['prjxray', 'utils']/" "$setup_py"
		rm -f "$setup_py.bak"
	fi
}

# These are installer-managed source trees. Submodules stay checked out, so
# reruns do not download them again, but their build products are removed so
# that a rerun builds from a clean tree instead of reusing stale objects.
clean_repo() (
	cd "$1"
	rm -rf build
	git clean -fdx
	git checkout -- .
	git submodule foreach --recursive git clean -ffdx
)

build_yosys() (
	cd "$1"
	cmake -S . -B build -DCMAKE_BUILD_TYPE=Release "${CMAKE_OPTS[@]}"
	cmake --build build --config Release --parallel "$(get_nproc)"
	cmake --install build --strip
)

build_nextpnr() (
	cd "$1"
	if [[ $(git rev-parse HEAD:xilinx/external/prjxray-db) != "$PRJXRAY_DB_HASH" ]]; then
		echo "Error: PRJXRAY_DB_HASH must match nextpnr's database submodule." >&2
		return 1
	fi
	local nextpnr_cmake_opts=("${CMAKE_OPTS[@]}" -DARCH=xilinx -DUSE_OPENMP=ON -DBUILD_GUI=OFF)
	if [[ "$OS" == Darwin ]]; then
		local llvm_prefix libomp_prefix
		llvm_prefix=$(brew --prefix llvm)
		libomp_prefix=$(brew --prefix libomp)
		nextpnr_cmake_opts+=("-DCMAKE_C_COMPILER=$llvm_prefix/bin/clang"
			"-DCMAKE_CXX_COMPILER=$llvm_prefix/bin/clang++")
		export CPATH="$libomp_prefix/include${CPATH:+:$CPATH}"
		export LIBRARY_PATH="$libomp_prefix/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
	fi
	cmake -S . -B build "${nextpnr_cmake_opts[@]}"
	cmake --build build --parallel "$(get_nproc)"
	cmake --install build
	cp build/bbasm "$INSTALL_PREFIX/bin/"
	cp xilinx/constids.inc "$INSTALL_PREFIX/lib/"
	cp xilinx/constids.inc xilinx/python/*.py "$INSTALL_PREFIX/lib/python/"
	# Copy contents, so a second install does not create external/external.
	mkdir -p "$INSTALL_PREFIX/lib/external"
	tar -C xilinx/external --exclude=.git -cf - . | tar -xf - -C "$INSTALL_PREFIX/lib/external"
	# Keep frame conversion in sync even when only nextpnr is rebuilt.
	build_prjxray_db xilinx/external/prjxray-db
)

build_prjxray() (
	cd "$1"
	patch_fasm_antlr_build
	patch_prjxray_setup
	cmake -S . -B build "${CMAKE_OPTS[@]}"
	cmake --build build --parallel "$(get_nproc)"
	cmake --install build

	# Earlier installers put a separate FASM in lib/python, which a PYTHONPATH
	# left over from their export.sh would load ahead of the venv's.
	rm -rf "$INSTALL_PREFIX/lib/python/fasm" "$INSTALL_PREFIX"/lib/python/fasm-*
	# An earlier run may have installed the local packages below in editable
	# mode. pip cannot always remove those, because their .pth and finder files
	# point outside the venv, and a leftover finder would take precedence over
	# what is installed here.
	rm -f "$INSTALL_PREFIX"/venv/lib/python*/site-packages/__editable__*{fasm,prjxray,sdf_timing}* \
		"$INSTALL_PREFIX"/venv/lib/python*/site-packages/__pycache__/__editable__*{fasm,prjxray,sdf_timing}*

	# requirements.txt installs the three local packages - FASM, python-sdf-timing
	# and prjxray itself - in editable mode, which would leave the venv importing
	# from this build directory. Such an installation would only work where that
	# directory is visible, which rules out sharing it between users or machines.
	# Install them as ordinary packages instead: FASM's own build puts the ANTLR
	# parser library and the generated extension into the package directory, so
	# the prefix references nothing outside itself.
	local requirements=requirements-installer.txt
	local editable=() entry
	while IFS= read -r entry; do
		editable+=("$entry")
	done < <(sed -nE 's/^[[:space:]]*(-e|--editable)[[:space:]]+(.*)$/\2/p' requirements.txt)
	if [[ ${#editable[@]} == 0 ]]; then
		requirements=requirements.txt
	else
		# sed rather than grep -v: an empty result must not fail under set -e,
		# which it does when every requirement is editable.
		sed -E '/^[[:space:]]*(-e|--editable)[[:space:]]/d' requirements.txt > "$requirements"
	fi

	# FASM defaults to its static ANTLR runtime. Install it once, in the venv.
	# FASM's bundled googletest uses uintptr_t without including <cstdint>, which
	# GCC 15's standard library no longer provides transitively.
	CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-include cstdint" python3 -m pip install -r "$requirements"
	if [[ ${#editable[@]} != 0 ]]; then
		CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-include cstdint" python3 -m pip install "${editable[@]}"
		rm -f "$requirements"
	fi

	# FASM's build can report success after silently falling back to textX.
	python3 -c 'import fasm.parser; assert fasm.parser.implementation == "antlr", "FASM ANTLR parser failed to build"; assert list(fasm.parser.parse_fasm_string("TEST.FEATURE"))[0].set_feature.feature == "TEST.FEATURE"'
	# The packages must not be installed editable: that would leave the venv
	# importing from this build directory, so an installation copied or shared
	# to another user or machine would only work where it is readable.
	python3 - <<-'PYEOF'
		import importlib.metadata as metadata
		import json
		import pathlib

		editable = []
		for name in ("fasm", "prjxray", "sdf_timing"):
		    direct_url = pathlib.Path(metadata.distribution(name)._path) / "direct_url.json"
		    if direct_url.exists() and json.loads(direct_url.read_text()).get("dir_info", {}).get("editable"):
		        editable.append(name)
		assert not editable, "installed editable: %s" % editable
	PYEOF
	fasm2frames --help >/dev/null
)

build_prjxray_db() {
	mkdir -p "$INSTALL_PREFIX/share/nextpnr/prjxray-db"
	git -C "$1" archive "$PRJXRAY_DB_HASH" | tar -xf - -C "$INSTALL_PREFIX/share/nextpnr/prjxray-db"
}

write_environment() {
	local pypy3_prefix=""
	if [[ "$OS" == Darwin ]]; then
		pypy3_prefix="$(brew --prefix pypy3)/bin:"
	fi
	cat >"$INSTALL_PREFIX/export.sh" <<EOF
# Python packages and console scripts live in the toolchain virtual environment.
export PATH="$INSTALL_PREFIX/venv/bin:$INSTALL_PREFIX/bin:$pypy3_prefix\$PATH"
export NEXTPNR_XILINX_PYTHON_DIR="$INSTALL_PREFIX/lib/python"
export PRJXRAY_DB_DIR="$INSTALL_PREFIX/share/nextpnr/prjxray-db"
EOF
}

main() {
	local build_yosys=false build_prjxray=false build_nextpnr=false tgt
	if [[ $# == 0 ]]; then
		set -- all
	fi
	for tgt in "$@"; do
		case "$tgt" in
			all) build_yosys=true; build_prjxray=true; build_nextpnr=true ;;
			yosys) build_yosys=true ;;
			prjxray) build_prjxray=true ;;
			nextpnr) build_nextpnr=true ;;
			*) echo "Usage: $0 [all | yosys prjxray nextpnr]" >&2; return 1 ;;
		esac
	done
	if [[ "$INSTALL_PREFIX" != /* ]]; then
		echo "Error: INSTALL_PREFIX must be an absolute path." >&2
		return 1
	fi
	if [[ -n "${JOBS:-}" && ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
		echo "Error: JOBS must be a positive integer." >&2
		return 1
	fi
	check_dependencies
	if [[ ! -d "$INSTALL_PREFIX" ]]; then
		if ! mkdir -p "$INSTALL_PREFIX" 2>/dev/null; then
			run_as_root mkdir -p "$INSTALL_PREFIX"
			run_as_root chown "$(id -u):$(id -g)" "$INSTALL_PREFIX"
		fi
	fi
	mkdir -p "$INSTALL_PREFIX/lib/python"
	local CMAKE_OPTS=("-DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX")
	if [[ "$OS" == Darwin ]]; then
		# Explicit prefixes also support Intel Homebrew under /usr/local.
		local brew_prefix
		brew_prefix=$(brew --prefix)
		PATH="$(brew --prefix openjdk)/bin:$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
		export PATH
		CMAKE_OPTS+=("-DCMAKE_PREFIX_PATH=$brew_prefix;$(brew --prefix tcl-tk);$(brew --prefix readline)")
	fi
	prepare_python
	CMAKE_BUILD_PARALLEL_LEVEL="$(get_nproc)"
	export CMAKE_BUILD_PARALLEL_LEVEL
	if [[ "$build_yosys" == true ]]; then
		git_clone_update yosys "$YOSYS_HASH"
		clean_repo yosys
		build_yosys yosys
	fi
	if [[ "$build_prjxray" == true ]]; then
		git_clone_update prjxray "$PRJXRAY_HASH"
		clean_repo prjxray
		build_prjxray prjxray
		git_clone_update prjxray-db "$PRJXRAY_DB_HASH"
		build_prjxray_db prjxray-db
	fi
	if [[ "$build_nextpnr" == true ]]; then
		git_clone_update nextpnr-xilinx "$NEXTPNR_XILINX_HASH"
		clean_repo nextpnr-xilinx
		build_nextpnr nextpnr-xilinx
	fi
	write_environment
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	main "$@"
fi
