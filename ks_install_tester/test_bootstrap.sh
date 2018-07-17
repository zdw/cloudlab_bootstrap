#!/usr/bin/env bash
#
# Copyright 2017-present Open Networking Foundation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# test_bootstrap.sh
# Bootstraps VM's for testing kubernetes-installer script
# runs only on Ubuntu 16.04

set -e -u -o pipefail

function cloudlab_setup() {

  # Don't do anything if not a CloudLab node
  [ ! -d /usr/local/etc/emulab ] && return

  # The watchdog will sometimes reset groups, turn it off
  if [ -e /usr/local/etc/emulab/watchdog ]
  then
    sudo /usr/bin/perl -w /usr/local/etc/emulab/watchdog stop
    sudo mv /usr/local/etc/emulab/watchdog /usr/local/etc/emulab/watchdog-disabled
  fi

  # Mount extra space, if haven't already
  if [ ! -d /mnt/extra ]
  then
    sudo mkdir -p /mnt/extra

    # for NVME SSD on Utah Cloudlab, not supported by mkextrafs
    if df | grep -q nvme0n1p1 && [ -e /usr/testbed/bin/mkextrafs ]
    then
      # set partition type of 4th partition to Linux, ignore errors
      printf "t\\n4\\n82\\np\\nw\\nq" | sudo fdisk /dev/nvme0n1 || true

      sudo mkfs.ext4 /dev/nvme0n1p4
      echo "/dev/nvme0n1p4 /mnt/extra/ ext4 defaults 0 0" | sudo tee -a /etc/fstab
      sudo mount /mnt/extra
      mount | grep nvme0n1p4 || (echo "ERROR: NVME mkfs/mount failed, exiting!" && exit 1)

    elif [ -e /usr/testbed/bin/mkextrafs ]  # if on Clemson/Wisconsin Cloudlab
    then
      # Sometimes this command fails on the first try
      sudo /usr/testbed/bin/mkextrafs -r /dev/sdb -qf "/mnt/extra/" || sudo /usr/testbed/bin/mkextrafs -r /dev/sdb -qf "/mnt/extra/"

      # Check that the mount succeeded (sometimes mkextrafs succeeds but device not mounted)
      mount | grep sdb || (echo "ERROR: mkextrafs failed, exiting!" && exit 1)
    fi
  fi

  # replace /var/lib/libvirt/images with a symlink
  [ -d /var/lib/libvirt/images/ ] && [ ! -h /var/lib/libvirt/images ] && sudo rmdir /var/lib/libvirt/images
  sudo mkdir -p /mnt/extra/libvirt_images /mnt/extra/docker /mnt/extra/kubelet

  if [ ! -e /var/lib/libvirt/images ]
  then
    sudo ln -s /mnt/extra/libvirt_images /var/lib/libvirt/images
    sudo ln -s /mnt/extra/docker /var/lib/docker
    sudo ln -s /mnt/extra/kubelet /var/lib/kubelet
  fi
}

echo "Installing prereqs..."
sudo apt-get update
sudo apt-get -y install apt-transport-https build-essential curl git python-dev \
                        python-pip software-properties-common sshpass \
                        qemu-kvm libvirt-bin libvirt-dev nfs-kernel-server socat


# this breaks things

echo "Install ansible and python modules"
sudo apt-get --auto-remove --yes remove python-openssl
pip install gitpython graphviz docker "Jinja2>=2.9" virtualenv ansible \
            ansible-modules-hashivault netaddr PyOpenSSL flake8 yamllint


if [ ! -x "/usr/bin/docker" ]
then
  # set up docker
  echo "Installing docker..."
  sudo apt-key adv --keyserver keyserver.ubuntu.com --recv 0EBFCD88
  sudo add-apt-repository \
        "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
         $(lsb_release -cs) \
         stable"

  sudo apt-get update
  sudo apt-get install -y "docker-ce=17.06*"
fi

if [ ! -e "${HOME}/.gitconfig" ]
then
  echo "No ${HOME}/.gitconfig, setting testing defaults..."
  git config --global user.name 'Test User'
  git config --global user.email 'test@null.com'
  git config --global color.ui false
fi

if [ ! -x "/usr/local/bin/repo" ]
then
  echo "Installing repo..."

  REPO_SHA256SUM="394d93ac7261d59db58afa49bb5f88386fea8518792491ee3db8baab49c3ecda"
  curl -o /tmp/repo 'https://gerrit.opencord.org/gitweb?p=repo.git;a=blob_plain;f=repo;hb=refs/heads/stable'
  echo "$REPO_SHA256SUM  /tmp/repo" | sha256sum -c -
  sudo cp /tmp/repo /usr/local/bin/repo
  sudo chmod a+x /usr/local/bin/repo
fi


if [ ! -d "${HOME}/cord" ]
then
  # make sure we can find gerrit.opencord.org as DNS failures will fail the build
  dig +short gerrit.opencord.org || (echo "ERROR: gerrit.opencord.org can't be looked up in DNS" && exit 1)

  echo "Downloading cord with repo..."
  pushd ${HOME}
  mkdir -p cord
  cd cord
  repo init -u https://gerrit.opencord.org/manifest -b master
  repo sync
  popd
fi

if [ ! -x "/usr/bin/vagrant" ]
then
  echo "Installing vagrant and associated tools..."

  VAGRANT_SHA256SUM="2f9498a83b3d650fcfcfe0ec7971070fcd3803fad6470cf7da871caf2564d84f"  # version 2.0.1
  curl -o /tmp/vagrant.deb https://releases.hashicorp.com/vagrant/2.0.1/vagrant_2.0.1_x86_64.deb
  echo "$VAGRANT_SHA256SUM  /tmp/vagrant.deb" | sha256sum -c -
  sudo dpkg -i /tmp/vagrant.deb
fi

cloudlab_setup

echo "Installing vagrant plugins if needed..."
VAGRANT_LIBVIRT_VERSION="0.0.40"
vagrant plugin list | grep -q vagrant-libvirt || vagrant plugin install vagrant-libvirt --plugin-version ${VAGRANT_LIBVIRT_VERSION}
vagrant plugin list | grep -q vagrant-mutate || vagrant plugin install vagrant-mutate

echo "Obtaining libvirt image of Ubuntu"
UBUNTU_VERSION=${UBUNTU_VERSION:-bento/ubuntu-16.04}
vagrant box list | grep "${UBUNTU_VERSION}" | grep virtualbox || vagrant box add --provider virtualbox "${UBUNTU_VERSION}"
vagrant box list | grep "${UBUNTU_VERSION}" | grep libvirt || vagrant mutate "${UBUNTU_VERSION}" libvirt --input-provider virtualbox


if [ ! -x "/usr/local/bin/kubectl" ]
then
  echo "Installing kubectl..."

  # install kubectl
  KUBECTL_VERSION="1.10.5"
  KUBECTL_SHA256SUM="a9e7f82e516aa8a652bc485620483ea964eb940787cabf890d7eab96eaac294d"
  curl -L -o /tmp/kubectl "https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  echo "$KUBECTL_SHA256SUM  /tmp/kubectl" | sha256sum -c -
  sudo cp /tmp/kubectl /usr/local/bin/kubectl
  sudo chmod a+x /usr/local/bin/kubectl
  rm -f /tmp/kubectl
fi


if [ ! -x "/usr/local/bin/helm" ]
then
  echo "Installing helm..."

  # install helm
  HELM_VERSION="2.9.1"
  HELM_SHA256SUM="56ae2d5d08c68d6e7400d462d6ed10c929effac929fedce18d2636a9b4e166ba"
  HELM_PLATFORM="linux-amd64"
  curl -L -o /tmp/helm.tgz "https://storage.googleapis.com/kubernetes-helm/helm-v${HELM_VERSION}-${HELM_PLATFORM}.tar.gz"
  echo "$HELM_SHA256SUM  /tmp/helm.tgz" | sha256sum -c -
  pushd /tmp
  tar -xzvf helm.tgz
  sudo cp ${HELM_PLATFORM}/helm /usr/local/bin/helm
  sudo chmod a+x /usr/local/bin/helm
  rm -rf helm.tgz ${HELM_PLATFORM}
  popd

  helm init --client-only
  helm repo add incubator https://kubernetes-charts-incubator.storage.googleapis.com/
fi

if [ ! -x "/usr/local/bin/minikube" ]
then
  echo "Installing minikube..."

  MINIKUBE_VERSION="0.28.0"
  MINIKUBE_DEB_VERSION="$(echo ${MINIKUBE_VERSION} | sed -n 's/\(.*\)\.\(.*\)/\1-\2/p')"
  MINIKUBE_SHA256SUM="5308f955f802a81cdb624fa8f6f5aeead642d203f25efd706cc55f04481bf7a3"
  curl -L -o /tmp/minikube.deb "https://storage.googleapis.com/minikube/releases/v${MINIKUBE_VERSION}/minikube_${MINIKUBE_DEB_VERSION}.deb"
  echo "$MINIKUBE_SHA256SUM  /tmp/minikube.deb" | sha256sum -c -
  pushd /tmp
  sudo dpkg -i minikube.deb
  rm -f minikube.deb
fi


echo "DONE!"

