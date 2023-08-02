#!/bin/bash

TMPDIR=$(mktemp -d)
cd $TMPDIR

YOSYS_VERSION=0.17
NEXTPNR_VERSION=0.5.0

function cleanup {
  cd
  rm -rf $TMPDIR
}

if [ ! -x "$(which yosys)" ]
then
  wget -c https://github.com/openXC7/yosys-snap/releases/download/v${YOSYS_VERSION}/yosys_${YOSYS_VERSION}_amd64.snap
  if [ $? -ne 0 ]
  then
    echo Downloading yosys package failed.
    cleanup
    exit 1
  fi
  sudo snap install --classic --dangerous ./yosys_*.snap
else
  echo "Yosys is already installed. Using your current installation"
fi

if [ -d /snap/nextpnr-kintex ]
then
  echo removing old toolchain version
  snap remove nextpnr-kintex
  cleanup
  exit 1
fi

if [ -d /snap/openxc7 ]
then
  echo openxc7 is already installed. Please remove it first, before running this script!
  cleanup
  exit 1
fi

wget -c https://github.com/openXC7/openXC7-snap/releases/download/v${NEXTPNR_VERSION}/openxc7_${NEXTPNR_VERSION}_amd64.snap
if [ $? -ne 0 ]
then
  echo Downloading openxc7 package failed.
  cleanup
  exit 1
fi

sudo snap install --classic --dangerous ./openxc7_*.snap
if [ $? -ne 0 ]
then
  echo installing openxc7 package failed.
  cleanup
  exit 1
fi

if [ ! -x "$(which nextpnr-xilinx)" ]
then
  sudo snap alias openxc7.nextpnr-xilinx nextpnr-xilinx
else
  echo nextpnr-xilinx already exists, refraining from creating an alias
fi

if [ ! -x "$(which bbasm)" ]
then
  sudo snap alias openxc7.bbasm bbasm
else
  echo bbasm already exists, refraining from creating an alias
fi

if [ ! -x "$(which fasm2frames)" ]
then
  sudo snap alias openxc7.fasm2frames fasm2frames
else
  echo fasm2frames already exists, refraining from creating an alias
fi

if [ ! -x "$(which xc7frames2bit)" ]
then
  sudo snap alias openxc7.xc7frames2bit xc7frames2bit
else
  echo xc7frames2bit already exists, refraining from creating an alias
fi

if [ ! -x "$(which bit2fasm)" ]
then
  sudo snap alias openxc7.bit2fasm bit2fasm
else
  echo bit2fasm already exists, refraining from creating an alias
fi
