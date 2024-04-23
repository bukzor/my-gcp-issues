It seems like there's no way to bring up a GCP project and a cloudfunction and
ensure that EventArc is ready to help provision the function.

```console
terraform init
terraform plan --refresh=false --out=tfplan
terraform apply tfplan
```

Results in error:

```
null_resource.cloudfunctions_ready: Creation complete after 0s [id=8232768214170766012]
google_cloudfunctions2_function._: Creating...
google_cloudfunctions2_function._: Still creating... [10s elapsed]
google_cloudfunctions2_function._: Still creating... [20s elapsed]
╷
│ Error: Error creating function: googleapi: Error 400: Validation failed for trigger projects/buckevan-issue-1--b87f95/locations/us/triggers/my-cool-function-001825: Invalid resource state for "": Permission denied while using the Eventarc Service Agent. If you recently started to use Eventarc, it may take a few minutes before all necessary permissions are propagated to the Service Agent. Otherwise, verify that it has Eventarc Service Agent role.
│
│   with google_cloudfunctions2_function._,
│   on main.tf line 161, in resource "google_cloudfunctions2_function" "_":
│  161: resource "google_cloudfunctions2_function" "_" {
│
╵
exit code: 1
duration: 2:09.612 minutes
```

If you want to retry, after that:

```
terraform taint random_id.project_suffix
terraform apply --refresh=false --auto-approve
```
