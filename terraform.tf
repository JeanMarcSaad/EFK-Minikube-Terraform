terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = ">= 2.0.0"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}


resource "kubernetes_namespace" "efk" {
  metadata {
    name = "efk"
  }
}

resource "kubernetes_service" "elasticsearch" {
  metadata {
    name = "elasticsearch"
    namespace = kubernetes_namespace.efk.metadata.0.name
    labels = {
      app = "elasticsearch"
    }
  }
  spec {
    selector = {
      app = "elasticsearch"
    }
    # cluster_ip = null
    port {
      name = "rest"
      port = 9200
    }
    port {
      name = "inter-node"
      port = 9300
    }
  }
}

resource "kubernetes_stateful_set" "elasticsearch" {
  metadata {
    name = "es-cluster"
    namespace = kubernetes_namespace.efk.metadata.0.name
  }

  spec {
    service_name = "elasticsearch"
    replicas = 3
    selector {
      match_labels = {
        app = "elasticsearch"
      }
    }
    template {
      metadata {
        labels = {
          app = "elasticsearch"
        }
      }
      spec {
        service_account_name = "prometheus"

        init_container {
          name              = "init-chown-data"
          image             = "busybox:latest"
          image_pull_policy = "IfNotPresent"
          command           = ["chown", "-R", "65534:65534", "/data"]

          volume_mount {
            name       = "prometheus-data"
            mount_path = "/data"
            sub_path   = ""
          }
        }

        container {
          name              = "elasticsearch"
          image             = "elasticsearch:7.5.0"
          image_pull_policy = "IfNotPresent"
          resources {
            limits = {
              cpu    = "1000m"
            }

            requests = {
              cpu    = "100m"
            }
          }
          port {
            container_port = 9200
            name = "rest"
            protocol = "TCP"
          }
          port {
            container_port = 9300
            name = "inter-node"
            protocol = "TCP"
          }
          volume_mount {
            name       = "data"
            mount_path = "/usr/share/elasticsearch/data"
          }
          env {
            name = "cluster.name"
            value = "k8s-logs"
          }
          env {
            name = "node.name"
            value = kubernetes_service.elasticsearch.metadata.0.name
          }
          env {
            name = "discovery.seed_hosts"
            value = "es-cluster-0.elasticsearch,es-cluster-1.elasticsearch,es-cluster-2.elasticsearch"
          }
          env {
            name = "cluster.initial_master_nodes"
            value = "es-cluster-0,es-cluster-1,es-cluster-2"
          }
          env {
            name = "ES_JAVA_OPTS"
            value = "-Xms512m -Xmx512m"
          }
        }
        init_container {
          name = "fix-permissions"
          image = "busybox"
          command = ["sh", "-c", "chown -R 1000:1000 /usr/share/elasticsearch/data"]
          volume_mount {
            name = "data"
            mount_path = "/usr/share/elasticsearch/data"
          }
        }
        init_container {
          name = "increase-vm-max-map"
          image = "busybox"
          command = ["sysctl", "-w", "vm.max_map_count=262144"]
        }
        init_container {
          name = "increase-fd-ulimit"
          image = "busybox"
          command = ["sh", "-c", "ulimit -n 65536"]
        }
      }
    }
    volume_claim_template {
      metadata {
        name = "data"
        labels = {
          app = "elasticsearch"
        }
      }
      spec {
        access_modes = [ "ReadWriteOnce" ]
        resources {
          requests = {
            storage = "3Gi"
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "kibana" {
  metadata {
    name      = "kibana"
    namespace = kubernetes_namespace.efk.metadata.0.name
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "kibana"
      }
    }
    template {
      metadata {
        labels = {
          app = "kibana"
        }
      }
      spec {
        container {
          image = "kibana:7.5.0"
          name  = "kibana-container"
          port {
            container_port = 5601
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "kibana" {
  metadata {
    name      = "kibana"
    namespace = kubernetes_namespace.efk.metadata.0.name
  }
  spec {
    selector = {
      app = kubernetes_deployment.kibana.spec.0.template.0.metadata.0.labels.app
    }
    type = "NodePort"
    port {
      port = 8080
      target_port = 5601
      node_port = 30000
      name = "kibana-port"
    }
  }
}

resource "kubernetes_cluster_role" "fluentd" {
  metadata {
    name = "fluentd"
    labels = {
      app = "fluentd"
    }
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces", "pods"]
    verbs      = ["get", "list", "watch"]
  }
}

# resource "kubernetes_service_account" "fluentd" {
#   metadata {
#     name = "fluentd"
#     namespace = kubernetes_namespace.efk.metadata.0.name
#     labels = {
#       app = "fluentd"
#     }
#   }
# }

resource "kubernetes_manifest" "fluentd_serviceaccount" {
  manifest = {
    "apiVersion" = "v1"
    "kind"       = "ServiceAccount"
    "metadata" = {
      "namespace" = kubernetes_namespace.efk.metadata.0.name
      "name"      = "fluentd"
      "labels" = {
        "app" = "fluentd"
      }
    }
  }
}

resource "kubernetes_cluster_role_binding" "fluentd" {
  metadata {
    name = "fluentd"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "fluentd"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "fluentd"
    namespace = kubernetes_namespace.efk.metadata.0.name
  }
  depends_on = [
    # kubernetes_service_account.fluentd,
    kubernetes_manifest.fluentd_serviceaccount,
    kubernetes_cluster_role.fluentd
  ]
}

resource "kubernetes_daemonset" "fluentd" {
  metadata {
    name      = "fluentd"
    namespace = kubernetes_namespace.efk.metadata.0.name
    labels = {
      app = "fluentd"
    }
  }
  spec {
    selector {
      match_labels = {
        app = "fluentd"
      }
    }
    template {
      metadata {
        labels = {
          app = "fluentd"
        }
      }
      spec {
        service_account_name = "fluentd"
        # service_account_name = kubernetes_service_account.fluentd.metadata.0.name
        container {
          name  = "fluentd"
          image = "fluentd-kubernetes-daemonset:v1.4.2-debian-elasticsearch-1.1"
          env {
            name = "FLUENT_ELASTICSEARCH_HOST"
            value = "elasticsearch.default.svc.cluster.local"
          }
          env {
            name = "FLUENT_ELASTICSEARCH_HOST"
            value = "elasticsearch.default.svc.cluster.local"
          }
          env {
            name = "FLUENT_ELASTICSEARCH_PORT"
            value = "9200"
          }
          env {
            name = "FLUENT_ELASTICSEARCH_SCHEME"
            value = "http"
          }
          env {
            name = "FLUENTD_SYSTEMD_CONF"
            value = "disable"
          }
          resources {
            limits = {
              memory = "512Mi"
            }
            requests = {
              cpu    = "100m"
              memory = "200Mi"
            }
          }
          volume_mount {
            name = "varlog"
            mount_path = "/var/log"
          }
          volume_mount {
            name = "varlibdockercontainers"
            mount_path = "/var/lib/docker/containers"
          }
        }
        termination_grace_period_seconds = 30
        volume {
            name = "varlog"
            host_path {
              path = "/var/log"
            }
        }
        volume {
            name = "varlibdockercontainers"
            host_path {
              path = "/var/lib/docker/containers"
            }
        }
      }
    }
  }
  depends_on = [
    kubernetes_cluster_role_binding.fluentd
  ]
}

resource "kubernetes_pod" "test" {
  metadata {
    name = "counter"
    namespace = kubernetes_namespace.efk.metadata.0.name
  }
  spec {
    container {
      name = "count"
      image = "busybox"
      args = [ "/bin/sh", "-c", "i=0; while true; do echo \"Thanks for visiting devopscube! $i\"; i=$((i+1)); sleep 1; done" ]
    }
  }
}