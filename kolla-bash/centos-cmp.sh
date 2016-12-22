#!/bin/bash

yum install bridge-utils -y

setenforce 0
sed -i "s/^\s*SELINUX=.*/SELINUX=disabled/g" /etc/selinux/config

yum -y install epel-release centos-release-openstack-newton

yum -y install \
    lvm2 \
    vim \
    net-tools \
    python-pip \
    python-devel \
    python-docker-py \
    python-openstackclient \
    python-neutronclient \
    libffi-devel \
    openssl-devel \
    gcc \
    make \
    ntp \
    docker

pip install -U pip

mkdir -p /etc/systemd/system/docker.service.d
tee /etc/systemd/system/docker.service.d/kolla.conf <<-EOF
[Service]
MountFlags=shared
EOF

systemctl daemon-reload
systemctl enable docker
systemctl enable ntpd.service
systemctl restart docker
systemctl restart ntpd.service

systemctl stop libvirtd.service
systemctl disable libvirtd.service

pip install ansible
