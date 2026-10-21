locals {
  # log_filter.txt is copied from lightlytics/gcp-deploymentmanager
  # code/gke-logs/setup-realtime.sh (LOG_FILTER) @ 7e5cf3c; keep in sync.
  base_filter = trimspace(file("${path.module}/log_filter.txt"))

  project_ids      = [for p in var.projects : p.project_id]
  include_projects = distinct(var.include_projects)
  include_clusters = distinct(var.include_clusters)
  exclude_clusters = distinct(var.exclude_clusters)

  gke_projects = length(local.include_projects) == 0 ? var.projects : {
    for k, p in var.projects : k => p if contains(local.include_projects, p.project_id)
  }

  deploy_projects = var.org_level_sink ? {
    (var.project_for_resources) = { project_for_resources = var.project_for_resources }
  } : local.gke_projects

  filter_clauses = compact([
    var.org_level_sink && length(local.include_projects) > 0 ? "(${join(" OR ", [for p in local.include_projects : "resource.labels.project_id=\"${p}\""])})" : "",
    length(local.include_clusters) > 0 ? "(${join(" OR ", [for c in local.include_clusters : "resource.labels.cluster_name=\"${c}\""])})" : "",
    length(local.exclude_clusters) > 0 ? "-(${join(" OR ", [for c in local.exclude_clusters : "resource.labels.cluster_name=\"${c}\""])})" : "",
  ])

  sink_filter = join("\n", concat([local.base_filter], local.filter_clauses))
}

resource "terraform_data" "inputs" {
  lifecycle {
    precondition {
      condition     = !var.org_level_sink || (var.organization_id != null && var.organization_id != "")
      error_message = "organization_id is required when org_level_sink is true."
    }
    precondition {
      condition     = !var.org_level_sink || contains(local.project_ids, var.project_for_resources)
      error_message = "project_for_resources must be an integrated project (one of projects) when org_level_sink is true."
    }
    precondition {
      condition     = alltrue([for p in local.include_projects : contains(local.project_ids, p)])
      error_message = "include_projects must only contain integrated projects."
    }
    precondition {
      condition     = var.org_level_sink || length(local.gke_projects) > 0
      error_message = "Project mode needs at least one GKE project."
    }
    precondition {
      condition     = length(setintersection(local.include_clusters, local.exclude_clusters)) == 0
      error_message = "A cluster name must not be in both include_clusters and exclude_clusters."
    }
    precondition {
      condition     = alltrue([for c in concat(local.include_clusters, local.exclude_clusters) : can(regex("^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$", c))])
      error_message = "Cluster names must match ^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$."
    }
    precondition {
      condition     = length(local.sink_filter) <= 20000
      error_message = "The sink filter is longer than 20,000 characters. Use fewer cluster names."
    }
  }
}
