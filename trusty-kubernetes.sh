#!/bin/bash
#
# This script is meant to be run on Ubuntu Trusty (14.04) as root
#
# It is expected that you are following the guide at:
# https://kubernetes.io/docs/setup/independent/install-kubeadm/
# https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
#
# Particularly you will need to have (BEFORE you start):
# - binutils, ebtables, socat installed
# - docker installed and running
# - kubernetes-cni and kubectl installed
# 
# It will create a directory in /tmp with the following artifacts in it:
# - nsenter binary (to be copied to /usr/local/bin)
# - kubelet-patched.deb (to be installed)
# - kubeadm-patched.deb (to be installed)
# (No changes on your system other than that directory)
#
# After you have done those steps do:
# - kubeadm init
# - start kubelet (from another shell, while kubeadm is waiting for the control plane)
# - continue with "(3/4) Installing a pod network"
# 
# * Credit *
# https://gist.github.com/lenartj
# https://gist.github.com/sjain2682


# Install kubernete in Ubunto 14
if [ -e /usr/bin/docker ]
then
        echo "* Docker is installed."
else
	apt-get install docker.io -y
	usermod -aG docker [YourUserNameHere]  
	service docker restart  
fi

apt-get update > /dev/null
apt-get install openssl make curl ethtool binutils ebtables socat git   -y


if [ -e /usr/bin/go ] 
then
	echo "* go is installed."
else
	wget https://dl.google.com/go/go1.10.linux-amd64.tar.gz
	tar -xvf go1.10.linux-amd64.tar.gz
	mv go /usr/local
	ln -s /usr/local/go/bin/go /usr/bin/go
	go version
fi

if [ -e /usr/bin/etcd ]
then
        echo "* etcd is installed."
else
	wget https://github.com/coreos/etcd/releases/download/v3.3.8/etcd-v3.3.8-linux-amd64.tar.gz
	tar xzvf etcd-v3.3.8-linux-amd64.tar.gz  >/dev/null
	pushd etcd-v3.3.8-linux-amd64 >/dev/null
	mv etcd* /usr/bin
	popd >/dev/null
	rm -rf etcd-v3.3.8-linux-amd64
	rm -rf etcd-v3.3.8-linux-amd64.tar.gz
fi

if [ -e /usr/bin/kubectl ]
then
  echo "* kubectl is installed."
else
apt-get update && apt-get install -y apt-transport-https \
  && curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
apt-get update > /dev/null
apt-get install -y kubernetes-cni kubectl cri-tools
fi

set -e
set -x

getpkg()
{
  local path=`apt-cache show "$1" | grep Filename | sort | tail -n1 | cut -d ' ' -f2`
  wget "https://packages.cloud.google.com/apt/$path"
}

unpkg()
{
  ar x "$1"
  gzip -dv control.tar.gz
  unxz -v data.tar.xz
}

repkg()
{
  gzip -v control.tar
  xz -v0 data.tar
  ar cr "$1" debian-binary control.tar.gz data.tar.xz
}

make_kubelet()
{
  rm -rf kubelet
  mkdir kubelet
  cd kubelet
  getpkg kubelet
  unpkg kubelet*deb

  # replace maintainer scripts
  tar xvf control.tar ./control
  sed 's/init-system-helpers (>= 1.18~)/init-system-helpers (>= 1.14~)/' -i control
  cat >prerm <<EOF
#!/bin/sh
stop kubelet || true
exit 0
EOF
  cat >postinst <<EOF
#!/bin/sh
exit 0
EOF
  cp postinst postrm
  tar --update -v -f control.tar ./control ./prerm ./postinst ./postrm

  # remove systemd unit
  tar --delete -v -f data.tar ./lib/systemd

  repkg ../kubelet-patched.deb
  cd ..
  rm -rf kubelet
}

make_kubeadm()
{
  mkdir kubeadm
  cd kubeadm
  getpkg kubeadm
  unpkg kubeadm*deb

  # replace maintainer scripts
  echo "/etc/init/kubelet.conf" >conffiles
  cat >postinst <<EOF
#!/bin/sh

[ "$1" = configure ] && restart kubelet
exit 0
EOF
  tar --update -v -f control.tar ./conffiles ./postinst

  # replace systemd unit
  mkdir -p etc/init
  cat >etc/init/kubelet.conf <<EOF
description "Kubelet"

start on (docker)
stop on runlevel [!2345]

limit nproc unlimited unlimited

respawn

kill timeout 30

script
        KUBELET_KUBECONFIG_ARGS="--kubeconfig=/etc/kubernetes/kubelet.conf --require-kubeconfig=true"
        KUBELET_SYSTEM_PODS_ARGS="--pod-manifest-path=/etc/kubernetes/manifests --allow-privileged=true"
        KUBELET_NETWORK_ARGS="--network-plugin=cni --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin"
        KUBELET_DNS_ARGS="--cluster-dns=10.96.0.10 --cluster-domain=cluster.local"
        KUBELET_AUTHZ_ARGS="--authorization-mode=Webhook --client-ca-file=/etc/kubernetes/pki/ca.crt"
        exec /usr/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_SYSTEM_PODS_ARGS \$KUBELET_NETWORK_ARGS \$KUBELET_DNS_ARGS \$KUBELET_AUTHZ_ARGS \$KUBELET_EXTRA_ARGS
end script
EOF
  tar --delete -v -f data.tar ./etc/systemd
  tar --add-file=./etc -r -v -f data.tar

  repkg ../kubeadm-patched.deb
  cd ..
  rm -rf kubeadm
}



make_nsenter()
{
cat <<EOF | docker run -i --rm -v "`pwd`:/tmp" ubuntu:14.04
apt-get update
apt-get install -y git bison
apt-get build-dep -y util-linux
apt-get install -y autopoint
apt-get install -y autoconf
apt-get install -y libtool
apt-get install -y gettext
apt-get install -y pkg-config
apt-get install -y make
cd /tmp
git clone git://git.kernel.org/pub/scm/utils/util-linux/util-linux.git
cd util-linux
./autogen.sh
./configure --without-python --disable-all-programs --enable-nsenter
make nsenter
EOF
cp -v util-linux/nsenter .
rm -rf util-linux
}



tmp=`mktemp -d`
cd "$tmp"


if [ -e /usr/bin/kubelet ]
then
        echo "* kubelet is installed."
else
	make_kubelet
fi

if [ -e /usr/bin/kubeadm ]
then
        echo "* kubeadm is installed."
else
	make_kubeadm
	dpkg -i $tmp/*-patched.deb
fi


if [ -e /usr/local/bin/nsenter ]
then
        echo "* nsente is installed."
else
	make_nsenter
	cp -v $tmp/nsenter /usr/local/bin
fi




