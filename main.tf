resource "random_id" "tag" {
  byte_length = 4
}

resource "tls_private_key" "installkey" {
  algorithm = "RSA"
  rsa_bits = "2048"
}

resource "local_file" "write_private_key" {
    content  = "${tls_private_key.installkey.private_key_pem}"
    filename = "${path.module}/artifacts/openshift_rsa"
}

resource "local_file" "write_public_key" {
    content  = "${tls_private_key.installkey.public_key_openssh}"
    filename = "${path.module}/artifacts/openshift_rsa.pub"
}

provider "vsphere" {
  version        = "~> 1.1"
  vsphere_server = "${var.vsphere_server}"

  # if you have a self-signed cert
  allow_unverified_ssl = "${var.vsphere_allow_unverified_ssl}"
}

##################################
#### Collect resource IDs
##################################
data "vsphere_datacenter" "dc" {
  name = "${var.vsphere_datacenter}"
}

data "vsphere_compute_cluster" "cluster" {
  name          = "${var.vsphere_cluster}"
  datacenter_id = "${data.vsphere_datacenter.dc.id}"
}

data "vsphere_datastore" "datastore" {
  count = "${var.datastore != "" ? 1 : 0}"

  name          = "${var.datastore}"
  datacenter_id = "${data.vsphere_datacenter.dc.id}"
}

data "vsphere_datastore_cluster" "datastore_cluster" {
  count = "${var.datastore_cluster != "" ? 1 : 0}"

  name          = "${var.datastore_cluster}"
  datacenter_id = "${data.vsphere_datacenter.dc.id}"
}

data "vsphere_resource_pool" "pool" {
  name          = "${var.vsphere_cluster}/Resources/${var.vsphere_resource_pool}"
  datacenter_id = "${data.vsphere_datacenter.dc.id}"
}

data "vsphere_network" "private_network" {
  name          = "${var.private_network_label}"
  datacenter_id = "${data.vsphere_datacenter.dc.id}"
}

data "vsphere_network" "public_network" {
  count         = "${var.public_network_label != "" ? 1 : 0}"
  name          = "${var.public_network_label}"
  datacenter_id = "${data.vsphere_datacenter.dc.id}"
}

# Create a folder
resource "vsphere_folder" "ocpenv" {
  count = "${var.folder != "" ? 1 : 0}"
  path = "${var.folder}"
  type = "vm"
  datacenter_id = "${data.vsphere_datacenter.dc.id}"
}

locals  {
  folder_path = "${var.folder != "" ?
        element(concat(vsphere_folder.ocpenv.*.path, list("")), 0)
        : ""}"
}

module "infrastructure" {
  source                       = "../../git/terraform-openshift3-infra-vmware"

  # vsphere information
  vsphere_server               = "${var.vsphere_server}"
  vsphere_cluster_id           = "${data.vsphere_compute_cluster.cluster.id}"
  vsphere_datacenter_id        = "${data.vsphere_datacenter.dc.id}"
  vsphere_resource_pool_id     = "${data.vsphere_resource_pool.pool.id}"
  private_network_id           = "${data.vsphere_network.private_network.id}"
  public_network_id            = "${var.public_network_label != "" ? data.vsphere_network.public_network.0.id : ""}"
  datastore_id                 = "${var.datastore != "" ? data.vsphere_datastore.datastore.0.id : ""}"
  datastore_cluster_id         = "${var.datastore_cluster != "" ? data.vsphere_datastore_cluster.datastore_cluster.0.id : ""}"
  folder_path                  = "${local.folder_path}"

  instance_name                = "${var.hostname_prefix}-${random_id.tag.hex}"

  public_staticipblock         = "${var.public_staticipblock}"
  public_staticipblock_offset  = "${var.public_staticipblock_offset}"
  public_gateway               = "${var.public_gateway}"
  public_netmask               = "${var.public_netmask}"
  public_domain                = "${var.public_domain}"
  public_dns_servers           = "${var.public_dns_servers}"

  private_staticipblock        = "${var.private_staticipblock}"
  private_staticipblock_offset = "${var.private_staticipblock_offset}"
  private_netmask              = "${var.private_netmask}"
  private_gateway              = "${var.private_gateway}"
  private_domain               = "${var.private_domain}"
  private_dns_servers          = "${var.private_dns_servers}"

  # how to ssh into the template
  template                     = "${var.template}"
  template_ssh_user            = "${var.ssh_username}"
  template_ssh_password        = "${var.ssh_password}"
  template_ssh_private_key     = "${file(var.ssh_private_key_file)}"

  # the keys to be added between bastion host and the VMs
  ssh_private_key              = "${tls_private_key.installkey.private_key_pem}"
  ssh_public_key               = "${tls_private_key.installkey.public_key_openssh}"

  # information about VM types
  master                       = "${var.master}"
  infra                        = "${var.infra}"
  worker                       = "${var.worker}"
  storage                      = "${var.storage}"
  bastion                      = "${var.bastion}"
}

module "console_loadbalancer" {
    source                  = "github.com/ibm-cloud-architecture/terraform-lb-haproxy-vmware"

    vsphere_server                = "${var.vsphere_server}"
    vsphere_allow_unverified_ssl  = "${var.vsphere_allow_unverified_ssl}"

    vsphere_datacenter_id     = "${data.vsphere_datacenter.dc.id}"
    vsphere_cluster_id        = "${data.vsphere_compute_cluster.cluster.id}"
    vsphere_resource_pool_id  = "${data.vsphere_resource_pool.pool.id}"
    datastore_id              = "${var.datastore != "" ? data.vsphere_datastore.datastore.0.id : ""}"
    datastore_cluster_id      = "${var.datastore_cluster != "" ? data.vsphere_datastore_cluster.datastore_cluster.0.id : ""}"

    # Folder to provision the new VMs in, does not need to exist in vSphere
    folder_path               = "${local.folder_path}"
    instance_name             = "${var.hostname_prefix}-${random_id.tag.hex}-console"

    private_network_id = "${data.vsphere_network.private_network.id}"
    private_ip_address = "${cidrhost(var.private_staticipblock, var.private_staticipblock_offset + var.bastion["nodes"] + var.master["nodes"] + var.infra["nodes"] + var.worker["nodes"] + var.storage["nodes"] + 1)}"
    private_netmask = "${var.private_netmask}"
    private_gateway = "${var.private_gateway}"
    private_domain               = "${var.private_domain}"

    public_network_id = "${var.public_network_label != "" ? data.vsphere_network.public_network.0.id : ""}"
    public_ip_address = "${var.public_network_label != "" ? cidrhost(var.public_staticipblock, var.public_staticipblock_offset + var.bastion["nodes"] + 1) : ""}"
    public_netmask = "${var.public_network_label != "" ? var.public_netmask: ""}"
    public_gateway = "${var.public_network_label != "" ? var.public_gateway : ""}"
    public_domain               = "${var.public_domain}"

    dns_servers = "${compact(concat(var.public_dns_servers, var.private_dns_servers))}"

    # how to ssh into the template
    template                         = "${var.template}"
    template_ssh_user                = "${var.ssh_username}"
    template_ssh_password            = "${var.ssh_password}"
    template_ssh_private_key         = "${file(var.ssh_private_key_file)}"

    rhn_username       = "${var.rhn_username}"
    rhn_password       = "${var.rhn_password}"
    rhn_poolid         = "${var.rhn_poolid}"

    bastion_ip_address      = "${module.infrastructure.bastion_public_ip}"

    frontend = ["443"]
    backend = {
        "443" = "${join(",", module.infrastructure.master_private_ip)}"
    }
}

module "app_loadbalancer" {
    source                  = "github.com/ibm-cloud-architecture/terraform-lb-haproxy-vmware"

    vsphere_server                = "${var.vsphere_server}"
    vsphere_allow_unverified_ssl  = "${var.vsphere_allow_unverified_ssl}"

    vsphere_datacenter_id     = "${data.vsphere_datacenter.dc.id}"
    vsphere_cluster_id        = "${data.vsphere_compute_cluster.cluster.id}"
    vsphere_resource_pool_id  = "${data.vsphere_resource_pool.pool.id}"
    datastore_id              = "${var.datastore != "" ? data.vsphere_datastore.datastore.0.id : ""}"
    datastore_cluster_id      = "${var.datastore_cluster != "" ? data.vsphere_datastore_cluster.datastore_cluster.0.id : ""}"

    # Folder to provision the new VMs in, does not need to exist in vSphere
    folder_path               = "${local.folder_path}"
    instance_name             = "${var.hostname_prefix}-${random_id.tag.hex}-app"

    private_network_id  = "${data.vsphere_network.private_network.id}"
    private_ip_address  = "${cidrhost(var.private_staticipblock, var.private_staticipblock_offset + var.bastion["nodes"] + var.master["nodes"] + var.infra["nodes"] + var.worker["nodes"] + var.storage["nodes"] + 2)}"
    private_netmask     = "${var.private_netmask}"
    private_gateway     = "${var.private_gateway}"
    private_domain      = "${var.private_domain}"

    public_network_id   = "${var.public_network_label != "" ? data.vsphere_network.public_network.0.id : ""}"
    public_ip_address   = "${var.public_network_label != "" ? cidrhost(var.public_staticipblock, var.public_staticipblock_offset + var.bastion["nodes"] + 2) : ""}"
    public_netmask      = "${var.public_network_label != "" ? var.public_netmask : ""}"
    public_gateway      = "${var.public_network_label != "" ? var.public_gateway : ""}"
    public_domain       = "${var.public_domain}"

    dns_servers = "${compact(concat(var.public_dns_servers, var.private_dns_servers))}"

    # how to ssh into the template
    template                         = "${var.template}"
    template_ssh_user                = "${var.ssh_username}"
    template_ssh_password            = "${var.ssh_password}"
    template_ssh_private_key         = "${file(var.ssh_private_key_file)}"

    bastion_ip_address      = "${module.infrastructure.bastion_public_ip}"

    rhn_username       = "${var.rhn_username}"
    rhn_password       = "${var.rhn_password}"
    rhn_poolid         = "${var.rhn_poolid}"

    frontend = ["80", "443"]
    backend = {
        "443" = "${join(",", module.infrastructure.infra_private_ip)}"
        "80" = "${join(",", module.infrastructure.infra_private_ip)}"
    }
}

module "ansible" {
  source = "github.com/ncolon/terraform-openshift-ansible.git?ref=v0.1"
  ssh_username            = "${var.ssh_username}"
  ssh_password            = "${var.ssh_password}"
  ssh_private_key         = "${tls_private_key.installkey.private_key_pem}"
  bastion_ip_address      = "${module.infrastructure.bastion_public_ip}"
  bastion_private_ip      = "${module.infrastructure.bastion_private_ip}"
  master_private_ip       = "${module.infrastructure.master_private_ip}"
  infra_private_ip        = "${module.infrastructure.infra_private_ip}"
  worker_private_ip       = "${module.infrastructure.worker_private_ip}"
  storage_private_ip      = "${module.infrastructure.storage_private_ip}"
  bastion_hostname        = "${module.infrastructure.bastion_hostname}"
  master_hostname         = "${module.infrastructure.master_hostname}"
  infra_hostname          = "${module.infrastructure.infra_hostname}"
  storage_hostname        = "${module.infrastructure.storage_hostname}"
  worker_hostname         = "${module.infrastructure.worker_hostname}"
  storage_count           = "${var.storage["nodes"]}"
  cluster_public_hostname = "${var.master_cname}"
  master_cluster_hostname = "${var.master_cname}"
  app_cluster_subdomain   = "${var.app_cname}"
  image_registry_username = "${var.image_registry_username}"
  image_registry_password = "${var.image_registry_password}"
  gluster_block_devices   = "${var.gluster_block_devices}"
  custom_inventory        = [
    "osm_use_cockpit=false",
    "openshift_storage_glusterfs_storageclass_default=false",
    "openshift_hosted_registry_storage_kind=vsphere",
    "openshift_hosted_registry_storage_access_modes=['ReadWriteOnce']",
    "openshift_hosted_registry_storage_annotations=['volume.beta.kubernetes.io/storage-provisioner: kubernetes.io/vsphere-volume']",
    "openshift_hosted_registry_replicas=1",
    "openshift_cloudprovider_kind=vsphere",
    "openshift_cloudprovider_vsphere_username=${var.vsphere_storage_username}",
    "openshift_cloudprovider_vsphere_password=${var.vsphere_storage_password}",
    "openshift_cloudprovider_vsphere_host=${var.vsphere_server}",
    "openshift_cloudprovider_vsphere_datacenter=${var.vsphere_datacenter}",
    "openshift_cloudprovider_vsphere_cluster=${var.vsphere_cluster}",
    "openshift_cloudprovider_vsphere_resource_pool=${var.vsphere_resource_pool}",
    "openshift_cloudprovider_vsphere_datastore=${var.vsphere_storage_datastore}",
    "openshift_cloudprovider_vsphere_folder=${var.folder}",
    "openshift_cloudprovider_vsphere_network=${var.public_network_label}"
  ]
  storageclass_block      = "vsphere-standard"
  storageclass_file       = "glusterfs"
}

module "rhnregister" {
  source = "github.com/ncolon/terraform-openshift-runplaybooks.git?ref=v0.1"
  ssh_username       = "${var.ssh_username}"
  ssh_password       = "${var.ssh_password}"
  ssh_private_key    = "${tls_private_key.installkey.private_key_pem}"
  bastion_ip_address = "${module.infrastructure.bastion_public_ip}"
  bastion_private_ip = "${module.infrastructure.bastion_private_ip}"
  master_private_ip  = "${module.infrastructure.master_private_ip}"
  infra_private_ip   = "${module.infrastructure.infra_private_ip}"
  worker_private_ip  = "${module.infrastructure.worker_private_ip}"
  storage_private_ip = "${module.infrastructure.storage_private_ip}"
  bastion_hostname   = "${module.infrastructure.bastion_hostname}"
  master_hostname    = "${module.infrastructure.master_hostname}"
  infra_hostname     = "${module.infrastructure.infra_hostname}"
  storage_hostname   = "${module.infrastructure.storage_hostname}"
  worker_hostname    = "${module.infrastructure.worker_hostname}"
  storage_count      = "${var.storage["nodes"]}"

  dependson          = [
    "${module.ansible.module_completed}"
  ]

  triggerson = {
    master  = "${var.master["nodes"]}"
    infra   = "${var.infra["nodes"]}"
    worker  = "${var.worker["nodes"]}"
    storage = "${var.storage["nodes"]}"
  }


  ansible_vars       = [
    "rhn_username = ${var.rhn_username}",
    "rhn_password = ${var.rhn_password}",
    "rhn_poolid  = ${var.rhn_poolid}"
  ]

  ansible_playbooks  = [
    "${module.ansible.playbook}/configure_rhn.yaml",
  ]
}


module "etchosts" {
  source = "github.com/ncolon/terraform-openshift-runplaybooks.git?ref=v0.1"
  ssh_username       = "${var.ssh_username}"
  ssh_password       = "${var.ssh_password}"
  ssh_private_key    = "${tls_private_key.installkey.private_key_pem}"
  bastion_ip_address = "${module.infrastructure.bastion_public_ip}"
  bastion_private_ip = "${module.infrastructure.bastion_private_ip}"
  master_private_ip  = "${module.infrastructure.master_private_ip}"
  infra_private_ip   = "${module.infrastructure.infra_private_ip}"
  worker_private_ip  = "${module.infrastructure.worker_private_ip}"
  storage_private_ip = "${module.infrastructure.storage_private_ip}"
  bastion_hostname   = "${module.infrastructure.bastion_hostname}"
  master_hostname    = "${module.infrastructure.master_hostname}"
  infra_hostname     = "${module.infrastructure.infra_hostname}"
  storage_hostname   = "${module.infrastructure.storage_hostname}"
  worker_hostname    = "${module.infrastructure.worker_hostname}"
  storage_count      = "${var.storage["nodes"]}"

  dependson          = [
    "${module.ansible.module_completed}",
    "${module.rhnregister.module_completed}"
  ]

  triggerson = {
    master  = "${var.master["nodes"]}"
    infra   = "${var.infra["nodes"]}"
    worker  = "${var.worker["nodes"]}"
    storage = "${var.storage["nodes"]}"
  }

  ansible_playbooks  = [
    "${module.ansible.playbook}/generate_etchosts.yaml",
  ]
}

module "prepare_nodes" {
  source = "github.com/ncolon/terraform-openshift-runplaybooks.git?ref=v0.1"
  ssh_username       = "${var.ssh_username}"
  ssh_password       = "${var.ssh_password}"
  ssh_private_key    = "${tls_private_key.installkey.private_key_pem}"
  bastion_ip_address = "${module.infrastructure.bastion_public_ip}"
  bastion_private_ip = "${module.infrastructure.bastion_private_ip}"
  master_private_ip  = "${module.infrastructure.master_private_ip}"
  infra_private_ip   = "${module.infrastructure.infra_private_ip}"
  worker_private_ip  = "${module.infrastructure.worker_private_ip}"
  storage_private_ip = "${module.infrastructure.storage_private_ip}"
  bastion_hostname   = "${module.infrastructure.bastion_hostname}"
  master_hostname    = "${module.infrastructure.master_hostname}"
  infra_hostname     = "${module.infrastructure.infra_hostname}"
  storage_hostname   = "${module.infrastructure.storage_hostname}"
  worker_hostname    = "${module.infrastructure.worker_hostname}"
  storage_count      = "${var.storage["nodes"]}"
 
  dependson          = [
    "${module.ansible.module_completed}",
    "${module.rhnregister.module_completed}",
    "${module.etchosts.module_completed}"
  ]

  triggerson = {
    master  = "${var.master["nodes"]}"
    infra   = "${var.infra["nodes"]}"
    worker  = "${var.worker["nodes"]}"
    storage = "${var.storage["nodes"]}"
  }

  ansible_vars       = [
    "docker_block_device = ${var.docker_block_device}",
    "openshift_vers = ${var.openshift_version}",
    "ansible_vers = ${var.ansible_version}",
  ]
  ansible_playbooks  = [
    "${module.ansible.playbook}/prepare_nodes.yaml"
  ]
}

module "prepare_bastion" {
  source = "github.com/ncolon/terraform-openshift-runplaybooks.git?ref=v0.1"
  ssh_username       = "${var.ssh_username}"
  ssh_password       = "${var.ssh_password}"
  ssh_private_key    = "${tls_private_key.installkey.private_key_pem}"
  bastion_ip_address = "${module.infrastructure.bastion_public_ip}"
  bastion_private_ip = "${module.infrastructure.bastion_private_ip}"
  master_private_ip  = "${module.infrastructure.master_private_ip}"
  infra_private_ip   = "${module.infrastructure.infra_private_ip}"
  worker_private_ip  = "${module.infrastructure.worker_private_ip}"
  storage_private_ip = "${module.infrastructure.storage_private_ip}"
  bastion_hostname   = "${module.infrastructure.bastion_hostname}"
  master_hostname    = "${module.infrastructure.master_hostname}"
  infra_hostname     = "${module.infrastructure.infra_hostname}"
  storage_hostname   = "${module.infrastructure.storage_hostname}"
  worker_hostname    = "${module.infrastructure.worker_hostname}"
  storage_count      = "${var.storage["nodes"]}"
 
  dependson          = [
    "${module.ansible.module_completed}",
    "${module.rhnregister.module_completed}",
    "${module.etchosts.module_completed}",
    "${module.prepare_nodes.module_completed}"
  ]

  triggerson = {
    bastion = "${var.bastion["nodes"]}"
  }

  ansible_vars       = [
    "docker_block_device = ${var.docker_block_device}",
    "openshift_vers = ${var.openshift_version}",
    "ansible_vers = ${var.ansible_version}",
  ]

  ansible_playbooks  = [
    "${module.ansible.playbook}/prepare_bastion.yaml"
  ]
}

module "openshift_prereqs" {
  source = "github.com/ncolon/terraform-openshift-runplaybooks.git?ref=v0.1"
  ssh_username       = "${var.ssh_username}"
  ssh_password       = "${var.ssh_password}"
  ssh_private_key    = "${tls_private_key.installkey.private_key_pem}"
  bastion_ip_address = "${module.infrastructure.bastion_public_ip}"
  bastion_private_ip = "${module.infrastructure.bastion_private_ip}"
  master_private_ip  = "${module.infrastructure.master_private_ip}"
  infra_private_ip   = "${module.infrastructure.infra_private_ip}"
  worker_private_ip  = "${module.infrastructure.worker_private_ip}"
  storage_private_ip = "${module.infrastructure.storage_private_ip}"
  bastion_hostname   = "${module.infrastructure.bastion_hostname}"
  master_hostname    = "${module.infrastructure.master_hostname}"
  infra_hostname     = "${module.infrastructure.infra_hostname}"
  storage_hostname   = "${module.infrastructure.storage_hostname}"
  worker_hostname    = "${module.infrastructure.worker_hostname}"
  storage_count      = "${var.storage["nodes"]}"
 
  dependson          = [
    "${module.ansible.module_completed}",
    "${module.rhnregister.module_completed}",
    "${module.etchosts.module_completed}",
    "${module.prepare_nodes.module_completed}",
    "${module.prepare_bastion.module_completed}",
  ]

  triggerson = {
    master  = "${var.master["nodes"]}"
    infra   = "${var.infra["nodes"]}"
    worker  = "${var.worker["nodes"]}"
    storage = "${var.storage["nodes"]}"
  }

  ansible_inventory = "${module.ansible.openshift_inventory}"
  ansible_playbooks = [
    "/usr/share/ansible/openshift-ansible/playbooks/prerequisites.yml"
  ]
}

module "openshift_deploy" {
  source = "github.com/ncolon/terraform-openshift-runplaybooks.git?ref=v0.1"
  ssh_username       = "${var.ssh_username}"
  ssh_password       = "${var.ssh_password}"
  ssh_private_key    = "${tls_private_key.installkey.private_key_pem}"
  bastion_ip_address = "${module.infrastructure.bastion_public_ip}"
  bastion_private_ip = "${module.infrastructure.bastion_private_ip}"
  master_private_ip  = "${module.infrastructure.master_private_ip}"
  infra_private_ip   = "${module.infrastructure.infra_private_ip}"
  worker_private_ip  = "${module.infrastructure.worker_private_ip}"
  storage_private_ip = "${module.infrastructure.storage_private_ip}"
  bastion_hostname   = "${module.infrastructure.bastion_hostname}"
  master_hostname    = "${module.infrastructure.master_hostname}"
  infra_hostname     = "${module.infrastructure.infra_hostname}"
  storage_hostname   = "${module.infrastructure.storage_hostname}"
  worker_hostname    = "${module.infrastructure.worker_hostname}"
  storage_count      = "${var.storage["nodes"]}"

  dependson          = [
    "${module.ansible.module_completed}",
    "${module.rhnregister.module_completed}",
    "${module.etchosts.module_completed}",
    "${module.prepare_nodes.module_completed}",
    "${module.prepare_bastion.module_completed}",
    "${module.openshift_prereqs.module_completed}",
  ]

  triggerson = {
    master  = "${var.master["nodes"]}"
    infra   = "${var.infra["nodes"]}"
    worker  = "${var.worker["nodes"]}"
    storage = "${var.storage["nodes"]}"
  }

  ansible_inventory = "${module.ansible.openshift_inventory}"
  ansible_playbooks = [
    "/usr/share/ansible/openshift-ansible/playbooks/deploy_cluster.yml"
  ]
}

