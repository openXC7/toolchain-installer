#!/bin/bash

TMPDIR=$(mktemp -d)
cd $TMPDIR

YOSYS_VERSION=0.17
NEXTPNR_VERSION=0.2.0

function cleanup {
  cd
  rm -rf $TMPDIR
}

if [ ! -x "$(which yosys)" ]
then
  wget -c https://github.com/kintex-chatter/yosys-snap/releases/download/v${YOSYS_VERSION}/yosys_${YOSYS_VERSION}_amd64.snap
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
  echo nextpnr-kintex is already installed. Please remove it first, before running this script!
  cleanup
  exit 1
fi

wget -c https://github.com/kintex-chatter/nextpnr-kintex-snap/releases/download/v${NEXTPNR_VERSION}/nextpnr-kintex_${NEXTPNR_VERSION}_amd64.snap
if [ $? -ne 0 ]
then
  echo Downloading nextpnr-kintex package failed.
  cleanup
  exit 1
fi

sudo snap install --classic --dangerous ./nextpnr-kintex_*.snap
if [ $? -ne 0 ]
then
  echo installing nextpnr-kintex package failed.
  cleanup
  exit 1
fi

if [ ! -x "$(which nextpnr-xilinx)" ]
then
  sudo snap alias nextpnr-kintex.nextpnr-xilinx nextpnr-xilinx
else
  echo nextpnr-xilinx already exists, refraining from creating an alias
fi

if [ ! -x "$(which bbasm)" ]
then
  sudo snap alias nextpnr-kintex.bbasm bbasm
else
  echo bbasm already exists, refraining from creating an alias
fi

if [ ! -x "$(which fasm2frames)" ]
then
  sudo snap alias nextpnr-kintex.fasm2frames fasm2frames
else
  echo fasm2frames already exists, refraining from creating an alias
fi

if [ ! -x "$(which xc7frames2bit)" ]
then
  sudo snap alias nextpnr-kintex.xc7frames2bit xc7frames2bit
else
  echo xc7frames2bit already exists, refraining from creating an alias
fi

if [ ! -x "$(which bit2fasm)" ]
then
  sudo snap alias nextpnr-kintex.bit2fasm bit2fasm
else
  echo bit2fasm already exists, refraining from creating an alias
fi
