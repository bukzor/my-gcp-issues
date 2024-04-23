# all provider versions are fully pinned, for reproducibility
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "5.26.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "5.26.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.1"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.2"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.4.2"
    }
  }
}

variable "org_id" {}
variable "billing_account" {}


# all provider configuration is done via environment
provider "google" {}
provider "google-beta" {}


# create a brand-new project
locals { project_id_prefix = "bukzor-issue-1" }
resource "random_id" "project_suffix" {
  byte_length = (30 - 2 - length(local.project_id_prefix)) / 2
}
resource "google_project" "_" {
  name       = "bukzor my-gcp-issues issue-1"
  project_id = "${local.project_id_prefix}--${random_id.project_suffix.hex}"

  org_id          = var.org_id
  billing_account = var.billing_account
}
locals { project = google_project._.project_id }


# enable eventarc service
resource "google_project_service" "eventarc" {
  project = local.project
  service = "eventarc.googleapis.com"
}
# force-create eventarc service agent
resource "google_project_service_identity" "eventarc" {
  project  = local.project
  provider = google-beta
  service  = google_project_service.eventarc.service
}
# force-create eventarc service agent IAM bindings
resource "google_project_iam_member" "eventarc" {
  project = local.project
  role    = "roles/eventarc.serviceAgent"
  member  = "serviceAccount:${google_project_service_identity.eventarc.email}"
}


# a bucket that will trigger the function, via pubsub
resource "google_storage_bucket" "gcf-trigger" {
  project                     = local.project
  name                        = "${local.project}--gcf-trigger"
  location                    = "us"
  uniform_bucket_level_access = true
}
data "google_storage_project_service_account" "_" {
  project = local.project
}
resource "google_project_iam_member" "gcs-pubsub" {
  project = local.project
  role    = "roles/pubsub.publisher"
  member  = data.google_storage_project_service_account._.member
}

# Permissions on the service account used by the function and Eventarc trigger
resource "google_project_iam_member" "function" {
  project = local.project
  for_each = toset([
    "roles/run.invoker",
    "roles/eventarc.eventReceiver",
    "roles/artifactregistry.reader",
  ])

  member = google_service_account.function.member
  role   = each.value
}


# a GCS bucket, for our cloudfunction's source code
resource "google_storage_bucket" "gcf-source" {
  project                     = local.project
  name                        = "${local.project}--gcf-source" # Every bucket name must be globally unique
  location                    = "us"
  uniform_bucket_level_access = true
}

# upload source code as a GCS object
data "archive_file" "function_source" {
  type        = "zip"
  source_dir  = "function"
  output_path = "function.zip"
  excludes    = []
}
resource "google_storage_bucket_object" "gcf-source" {
  name   = data.archive_file.function_source.output_path
  source = data.archive_file.function_source.output_path
  bucket = google_storage_bucket.gcf-source.name
}

resource "google_service_account" "function" {
  project    = local.project
  account_id = "my-cool-function"
}

# grant actAs to the caller
data "google_client_openid_userinfo" "_" {}
resource "google_service_account_iam_member" "function" {
  service_account_id = google_service_account.function.id
  member             = "user:${data.google_client_openid_userinfo._.email}"
  role               = "roles/iam.serviceAccountUser"
}

# enable cloudfunctions
resource "google_project_service" "cloudfunctions" {
  project = local.project
  service = "cloudfunctions.googleapis.com"
}
resource "google_project_service" "run" {
  project = local.project
  service = "run.googleapis.com"
}
resource "google_project_service" "cloudbuild" {
  project = local.project
  service = "cloudbuild.googleapis.com"
}
resource "null_resource" "cloudfunctions_ready" {
  triggers = {
    project = local.project
    deps = jsonencode([
      google_project_service.cloudfunctions.id,
      google_project_service.run.id,
      google_project_service.cloudbuild.id,
      google_project_service.eventarc.id,
      # wait for the EventArc Service Agent permissions
      google_project_iam_member.eventarc.role,
      # wait for the function's SA permissions
      google_project_iam_member.function,
    ])
  }
}


# provision a cloudfunction
resource "google_cloudfunctions2_function" "_" {
  project     = null_resource.cloudfunctions_ready.triggers.project
  name        = google_service_account.function.account_id
  location    = "us-central1"
  description = "a new function"

  build_config {
    runtime     = "python312"
    entry_point = "main" # Set the entry point 
    source {
      storage_source {
        bucket = google_storage_bucket.gcf-source.name
        object = google_storage_bucket_object.gcf-source.name
      }
    }
  }
  service_config {
    service_account_email = google_service_account.function.email
  }
  event_trigger {
    trigger_region        = "us"
    event_type            = "google.cloud.storage.object.v1.finalized"
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.function.email
    event_filters {
      attribute = "bucket"
      value     = google_storage_bucket.gcf-trigger.name
    }
  }
}

output "function_uri" {
  value = google_cloudfunctions2_function._.service_config[0].uri
}
