Installing and configuring collectd agent on other machines
===========================================================

Collectd configurations are built for these types of machines:
  * baremetal
  * guest
  * graphite/grafana
  * ose
  * satellite6

To install collectd agent and configure collectd to send metrics to your
Graphite server, simply add the host to your ansible inventory file
under the correct group.

Complete Example Inventory file:

::

    [undercloud]
    undercloud

    [controller]
    overcloud-controller-0
    overcloud-controller-1
    overcloud-controller-2

    [compute]
    overcloud-compute-0
    overcloud-compute-1

    [ceph]
    overcloud-cephstorage-0

    [baremetal]
    x.x.x.x # An ip adddress or fqdn or specificed host in ~/.ssh/config

    [guest]
    x.x.x.x # An ip adddress or fqdn or specificed vm in ~/.ssh/config

    [graphite]
    x.x.x.x # An ip address of a Graphite/Grafana Server

    [ose]
    x.x.x.x # An ip address of a Red Hat Openshift Enterprise Node

    [satellite6]
    x.x.x.x # An ip address of a Red Hat Satellite 6 Server

Example running the collectd-generic playbook on the above specified
satellite6 machine:

::

    # ansible-playbook -i hosts install/collectd-generic.yml --tags "satellite6"

Replace "satellite6" with whatever machines you intend to install collectd on.

Note: Openstack host groups (undercloud, controller, compute, ceph) are
ignored with the collectd-generic.yml playbook.
