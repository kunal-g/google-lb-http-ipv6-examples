/**
 * Copyright 2017 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

provider "google" {
  project = var.project
}

provider "google-beta" {
  project = var.project
}

resource "google_compute_network" "default" {
  name                    = var.network_name
  description             = "Default network for the project"
  auto_create_subnetworks = true
  timeouts {
    create = null
    delete = null
    update = null
  }
}

resource "google_compute_subnetwork" "default" {
  name                     = var.network_name
  ip_cidr_range            = "10.160.0.0/20"
  network                  = google_compute_network.default.self_link
  region                   = var.region
  private_ip_google_access = false

  timeouts {
    create = null
    delete = null
    update = null
  }
}

resource "google_compute_router" "default" {
  name    = "lb-https-redirect-router"
  network = google_compute_network.default.self_link
  region  = var.region
}

module "cloud-nat" {
  source     = "terraform-google-modules/cloud-nat/google"
  version    = "1.0.0"
  router     = google_compute_router.default.name
  project_id = var.project
  region     = var.region
  name       = "cloud-nat-lb-https-redirect"
}

data "template_file" "group-startup-script" {
  template = file(format("%s/gceme.sh.tpl", path.module))

  vars = {
    PROXY_PATH = ""
  }
}

module "mig_template" {
  source     = "terraform-google-modules/vm/google//modules/instance_template"
  version    = "1.0.0"
  network    = google_compute_network.default.self_link
  subnetwork = google_compute_subnetwork.default.self_link
  service_account = {
    email  = ""
    scopes = ["cloud-platform"]
  }
  name_prefix    = var.network_name
  startup_script = data.template_file.group-startup-script.rendered
  tags = [
    var.network_name,
    module.cloud-nat.router_name
  ]
  
  source_image_project  = "centos-cloud"
  source_image_family   = "centos-8"
}

module "mig" {
  source            = "terraform-google-modules/vm/google//modules/mig"
  version           = "1.0.0"
  instance_template = module.mig_template.self_link
  region            = var.region
  hostname          = var.network_name
  target_size       = 2
  named_ports = [{
    name = "http",
    port = 80
  }]
  network    = google_compute_network.default.self_link
  subnetwork = google_compute_subnetwork.default.self_link
}

module "gce-lb-http" {
  source               = "github.com/kunal-g/terraform-google-lb-http?ref=issue-112-dual-stack"
  name                 = "ci-https-redirect"
  project              = var.project
  target_tags          = [var.network_name]
  firewall_networks    = [google_compute_network.default.name]
  ssl                  = true
  ssl_certificates     = [google_compute_ssl_certificate.example.self_link]
  use_ssl_certificates = true
  https_redirect       = true

  ## ipv4 config
  create_address       = true
  ## ipv4 config

  ## ipv6 config
  enable_ipv6          = true

  ## let's use the default value from variables.tf
  ## which is set to "new"
  # ipv6_address         = var.ipv6_address
  
  ## ipv6 config

  backends = {
    default = {
      description                     = null
      protocol                        = "HTTP"
      port                            = 80
      port_name                       = "http"
      timeout_sec                     = 10
      connection_draining_timeout_sec = null
      enable_cdn                      = false
      security_policy                 = null
      session_affinity                = null
      affinity_cookie_ttl_sec         = null
      custom_request_headers          = null

      health_check = {
        check_interval_sec  = null
        timeout_sec         = null
        healthy_threshold   = null
        unhealthy_threshold = null
        request_path        = "/"
        port                = 80
        host                = null
        logging             = null
      }

      log_config = {
        enable      = false
        sample_rate = null
      }

      groups = [
        {
          group                        = module.mig.instance_group
          balancing_mode               = null
          capacity_scaler              = null
          description                  = null
          max_connections              = null
          max_connections_per_instance = null
          max_connections_per_endpoint = null
          max_rate                     = null
          max_rate_per_instance        = null
          max_rate_per_endpoint        = null
          max_utilization              = null
        }
      ]
      iap_config = {
        enable               = false
        oauth2_client_id     = ""
        oauth2_client_secret = ""
      }
    }
  }

}
