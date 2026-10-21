# GKE audit logs (real-time)

Sends GKE audit logs to Stream Security in real time: log sink, Pub/Sub topic, and a Cloud Function (gen2) that forwards each entry.

Two modes, set by `org_level_sink`:

- `true`: one organization sink, topic, and function in `project_for_resources`. Needs `organization_id`.
- `false`: one project sink, topic, and function in each project of `projects` (narrowed by `include_projects`).

| Variable | Description | Default |
|---|---|---|
| `org_level_sink` | Organization sink (`true`) or per-project sinks (`false`). | required |
| `organization_id` | Organization ID, for the org sink. | `null` |
| `project_for_resources` | Deploy project in org mode. Must be an integrated project. | `""` |
| `projects` | Integrated projects (`project_id`, `name`). | required |
| `include_projects` | Collect only from these projects. | `[]` |
| `include_clusters` | Collect only these cluster names. | `[]` |
| `exclude_clusters` | Skip these cluster names. | `[]` |
| `region` | Function region. | `us-central1` |
| `secret_name` | Secret holding the collection token. | `streamsec-gke-logs-token` |
| `source_bucket`, `source_object` | Function source zip. | Stream Security public artifacts |

If you set up GKE audit logs with `setup-realtime.sh` in a project, remove it first: `bash setup-realtime.sh --project <PROJECT_ID> --uninstall --delete-secret`.

Cluster and project lists are Terraform inputs; `setup-prerequisites.sh` does not set them.

Org mode collects every project in the organization (also projects excluded from the integration) unless `gke_include_projects` is set; cluster names match in every project.
