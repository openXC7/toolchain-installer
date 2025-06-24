#!/usr/bin/bash

# Install directory
INSTALL_PREFIX=/opt/openxc7

# Option to use with cmake.
CMAKE_OPTS="-DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX"

# Tools dependencies.
DEPENDENCIES="cmake default-jre-headless uuid-dev libantlr4-runtime-dev"
DEPENDENCIES="$DEPENDENCIES python3-setuptools cython3"
DEPENDENCIES="$DEPENDENCIES libboost-iostreams-dev libboost-thread-dev libboost-program-options-dev"
DEPENDENCIES="$DEPENDENCIES libboost-python-dev libeigen3-dev"
# pip / prjxray
DEPENDENCIES="$DEPENDENCIES python3-intervaltree python3-numpy python3-openpyxl python3-ordered-set"
DEPENDENCIES="$DEPENDENCIES python3-parse python3-progressbar2 python3-json5 python3-pytest python3-yaml"
DEPENDENCIES="$DEPENDENCIES python3-pytest-runner python3-scipy python3-simplejson python3-sympy python3-yapf"

# Tools commit hash.
# Yosys
YOSYS_HASH=yosys-0.38
# nextpnr xilinx (stable-backports 2025-03-10)
NEXTPNR_XILINX_HASH=3374e5a62b54dc346fd5f85188ed24075ddfd5fb
NEXTPNR_XILINX_HASH=0.8.2
# prjxray (master 2025-02-19)
PRJXRAY_HASH=ce065d470ea9547bba97b9df4476a0148e728c95
# prjxray-db (master 2025-02-19)
PRJXRAY_DB_HASH=0.8.2

check_dependencies() {
	dep_install=""
	for package in $DEPENDENCIES; do
		ret=$(dpkg -l | grep $package)
		if [[ "$ret" == "" ]]; then
			#dep_install="$dep_install$package "
			dep_install+="$package "
		fi
	done

	if [[ $dep_install != "" ]]; then
		echo "Missing package: $dep_install"
		echo "sudo apt install $dep_install"
		sudo apt install $dep_install
	fi
}

git_clone_update() {
	if [[ $# == 0 ]]; then
		echo "wrong arguments"
		return
	fi

	repo=$1
	if [[ $2 == "" ]]; then
		repo_hash=""
	else
		repo_hash=$2
	fi

	if [ -d $repo ]; then
		pushd $repo
		git checkout .
		git pull
	else
		case "$repo" in
			nextpnr-xilinx)
		 		repo_url="https://github.com/openXC7/nextpnr-xilinx.git";;
			yosys)
				repo_url="https://github.com/YosysHQ/yosys.git";;
			prjxray)
				repo_url="https://github.com/openXC7/prjxray.git";;
			prjxray-db)
				repo_url="https://github.com/openXC7/prjxray-db.git";;
			*)
				echo "Error: unknown repo $repo"
				return;;
		esac

		git clone $repo_url $repo
   		pushd $repo
	fi

	# Force specified hash.
	if [[ $repo_hash != "" ]]; then
		git checkout $repo_hash
	fi
   	git submodule update --init --recursive
   	popd
}

clean_repo() {
	if [[ $# != 1 ]]; then
		echo "wrong arguments"
		return
	fi

	repo=$1

	pushd $repo
	make clean
	git clean -fd .
	git clean -fX .
	git clean -fx .
	git checkout .
	git clean -fd && git clean -fX && git clean -fx
	popd
}

build_yosys() {
	repo=$1
	pushd $repo
	make -j$(nproc)
	make install PREFIX=$INSTALL_PREFIX
	popd
}

build_fasm() {
	#apt install cmake default-jre-headless uuid-dev libantlr4-runtime-dev
	#apt install python3-setuptools cython3
	#git submodule update --init
	pushd prjxray/third_party/fasm
	python3 setup.py install --verbose --antlr-runtime=shared --home=$INSTALL_PREFIX
	popd
}

build_nextpnr() {
	# apt install libboost-iostreams-dev libboost-thread-dev libboost-program-options-dev
	# apt install libboost-python-dev libeigen3-dev
	if [[ $# > 1 ]]; then
		echo "Error: too many args"
		return
	fi
	[ -d $1/build ] || mkdir -p $1/build
	pushd $1/build
	sed -i "s/foreach (PyVer 3 36 37 38 39 310 311 312)/foreach (PyVer 3 36 37 38 39 310 311 312 313)/g" ../CMakeLists.txt

	cmake $CMAKE_OPTS -DARCH=xilinx -DUSE_OPENMP=ON -DBUILD_GUI=OFF ..
	make -j$(nproc)
	make install
	cp bbasm $INSTALL_PREFIX/bin
	#cp ../xilinx/python/bbaexport.py $INSTALL_PREFIX/bin/bbaexport
	cp ../xilinx/constids.inc $INSTALL_PREFIX/lib/
	cp ../xilinx/constids.inc ../xilinx/python/* $INSTALL_PREFIX/lib/python/
	cp -r ../xilinx/external $INSTALL_PREFIX/lib/external
	popd 
}

build_prjxray() {
	pushd $1
	mkdir -p build
	pushd build
	cmake $CMAKE_OPTS ..
	make -j$(nproc)
	make install
	popd

	pip3 install --user -r requirements.txt
	popd
}

build_prjxray_db() {
	pushd $1
	[ -d $INSTALL_PREFIX/share/nextpnr ] || mkdir -p $INSTALL_PREFIX/share/nextpnr/prjxray-db
	cp -fr * $INSTALL_PREFIX/share/nextpnr/prjxray-db
	popd
}

if [ ! -d $INSTALL_PREFIX ]; then
	sudo mkdir -p $INSTALL_PREFIX
	sudo chown -R $UID:$GROUPS $INSTALL_PREFIX
fi

# check if everything must be build or only one step.
build_yosys="false"
build_prjxray="false"
build_nextpnr="false"

if [[ $# == 0 ]]; then
	build_yosys="true"
	build_prjxray="true"
	build_nextpnr="true"
else
	if [[ $1 == "all" ]]; then
		build_yosys="true"
		build_prjxray="true"
		build_nextpnr="true"
	else
		for tgt in $@; do
			if [[ $tgt == "yosys" ]]; then
				build_yosys="true"
			fi
			if [[ $tgt == "prjxray" ]]; then
				build_prjxray="true"
			fi
			if [[ $tgt == "nextpnr" ]]; then
				build_nextpnr="true"
			fi
		done
	fi
fi

# Check/Install Dependencies
check_dependencies

# YOSYS
if [[ $build_yosys == "true" ]]; then
	git_clone_update yosys $YOSYS_HASH
	clean_repo yosys
	build_yosys yosys
fi

# PRJXRAY + PRJXRAY-DB + FASM
if [[ $build_prjxray == "true" ]]; then
	git_clone_update prjxray
	clean_repo prjxray
	build_prjxray prjxray

	git_clone_update prjxray-db $PRJXRAY_DB_HASH
	build_prjxray_db prjxray-db

	build_fasm
fi

# NEXTPNR XILINX
if [[ $build_nextpnr == "true" ]]; then
	git_clone_update nextpnr-xilinx $NEXTPNR_XILINX_HASH
	clean_repo nextpnr-xilinx
	build_nextpnr nextpnr-xilinx
fi

if [ ! -d $INSTALL_PREFIX/export.sh ]; then
	cat << EOF > $INSTALL_PREFIX/export.sh
export PYTHONPATH=$INSTALL_PREFIX/lib/python
export PATH=$INSTALL_PREFIX/bin:\$PATH
export NEXTPNR_XILINX_PYTHON_DIR=$INSTALL_PREFIX/lib/python
export PRJXRAY_DB_DIR=$INSTALL_PREFIX/share/nextpnr/prjxray-db
EOF
fi
