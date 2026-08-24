data "local_file" "cloudinit" {
  filename = "${path.module}/scripts/cloudinit.yaml"
}
