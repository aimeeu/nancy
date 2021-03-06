#!/bin/bash
# Copyright 2017 Bryan Sullivan
#  
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#  
# http://www.apache.org/licenses/LICENSE-2.0
#  
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# What this is: Functions for testing with Prometheus. 
# Prerequisites: 
# - Ubuntu server for master and agent nodes

#. Usage:
#. $ git clone https://github.com/blsaws/nancy.git 
#. $ cd nancy/prometheus
#. $ bash prometheus-tools.sh setup "<list of agent nodes>"
#. <list of agent nodes>: space separated IP of agent nodes
#. $ bash prometheus-tools.sh clean "<list of agent nodes>"
#

# Prometheus links
# https://prometheus.io/download/
# https://prometheus.io/docs/introduction/getting_started/
# https://github.com/prometheus/prometheus
# https://prometheus.io/docs/instrumenting/exporters/
# https://github.com/prometheus/node_exporter
# https://github.com/prometheus/haproxy_exporter
# https://github.com/prometheus/collectd_exporter

function setup_prometheus() {
  # Prerequisites
  echo "$0: Setting up prometheus master and agents"
  sudo apt install -y golang-go jq

  # Install Prometheus server
  echo "$0: Setting up prometheus master"
  if [[ -d ~/prometheus ]]; then rm -rf ~/prometheus; fi
  mkdir ~/prometheus
  mkdir ~/prometheus/dashboards
  cp -r dashboards/* ~/prometheus/dashboards
  cd  ~/prometheus
  wget https://github.com/prometheus/prometheus/releases/download/v2.0.0-beta.2/prometheus-2.0.0-beta.2.linux-amd64.tar.gz
  tar xvfz prometheus-*.tar.gz
  cd prometheus-*
  # Customize prometheus.yml below for your server IPs
  # This example assumes the node_exporter and haproxy_exporter will be installed on each node
  cat <<'EOF' >prometheus.yml
global:
  scrape_interval:     15s # By default, scrape targets every 15 seconds.

  # Attach these labels to any time series or alerts when communicating with
  # external systems (federation, remote storage, Alertmanager).
  external_labels:
    monitor: 'codelab-monitor'

# A scrape configuration containing exactly one endpoint to scrape:
# Here it's Prometheus itself.
scrape_configs:
  # The job name is added as a label `job=<job_name>` to any timeseries scraped from this config.
  - job_name: 'prometheus'

    # Override the global default and scrape targets from this job every 5 seconds.
    scrape_interval: 5s

    static_configs:
EOF

  for node in $nodes; do
    echo "      - targets: ['${node}:9100']" >>prometheus.yml
    echo "      - targets: ['${node}:9101']" >>prometheus.yml
  done

  # Start Prometheus
  nohup ./prometheus --config.file=prometheus.yml &
  # Browse to http://host_ip:9090

  echo "$0: Installing exporters"
  # Install exporters
  # https://github.com/prometheus/node_exporter
  cd ~/prometheus
  wget https://github.com/prometheus/node_exporter/releases/download/v0.14.0/node_exporter-0.14.0.linux-amd64.tar.gz
  tar xvfz node*.tar.gz
  # https://github.com/prometheus/haproxy_exporter
  #wget https://github.com/prometheus/haproxy_exporter/releases/download/v0.7.1/haproxy_exporter-0.7.1.linux-amd64.tar.gz
  #tar xvfz haproxy*.tar.gz

  # The scp and ssh actions below assume you have key-based access enabled to the nodes
  for node in $nodes; do
    echo "$0: Setup agent at $node"
    scp -r -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      node_exporter-0.14.0.linux-amd64/node_exporter ubuntu@$node:/home/ubuntu/node_exporter
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node "nohup ./node_exporter > /dev/null 2>&1 &"
    scp -r -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      haproxy_exporter-0.7.1.linux-amd64/haproxy_exporter ubuntu@$node:/home/ubuntu/haproxy_exporter
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node "nohup ./haproxy_exporter > /dev/null 2>&1 &"
  done
}

function connect_grafana() {
  echo "$0: Setup Grafana"
  prometheus_ip=$1
  grafana_ip=$2

  echo "$0: Setup Prometheus datasource for Grafana"
  cd ~/prometheus/
  cat >datasources.json <<EOF
{"name":"Prometheus", "type":"prometheus", "access":"proxy", \
"url":"http://$prometheus_ip:9090/", "basicAuth":false,"isDefault":true }
EOF
  curl -X POST -u admin:admin -H "Accept: application/json" \
    -H "Content-type: application/json" \
    -d @datasources.json http://admin:admin@$grafana_ip:3000/api/datasources

  echo "$0: Import Grafana dashboards"
  # Setup Prometheus dashboards
  # https://grafana.com/dashboards?dataSource=prometheus
  # To add additional dashboards, browse the URL above and import the dashboard via the id displayed for the dashboard
  # Select the home icon (upper left), Dashboards / Import, enter the id, select load, and select the Prometheus datasource

  cd ~/prometheus/dashboards
  boards=$(ls)
  for board in $boards; do
    sed -i -- "s/  \"id\": null,\a
    curl -X POST -u admin:password -H \"Accept: application/json\" \
      -H \"Content-type: application/json\" \
      -d @${board} http://admin:admin@$grafana_ip:3000/api/dashboards/db"
  done
}

nodes=$2
case "$1" in
  setup)
    setup_prometheus
    ;;
  grafana)
    # Per http://docs.grafana.org/installation/docker/
    host_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
    sudo docker run -d -p 3000:3000 --name grafana grafana/grafana
    connect_grafana $host_ip $host_ip
  clean)
    sudo kill $(ps -ef | grep "\./prometheus" | grep prometheus.yml | awk '{print $2}')
    rm -rf ~/prometheus
    sudo docker stop grafana
    sudo docker rm grafana
    for node in $nodes; do
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ubuntu@$node "sudo kill $(ps -ef | grep ./node_exporter | awk '{print $2}')"
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ubuntu@$node "rm -rf /home/ubuntu/node_exporter"
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ubuntu@$node "sudo kill $(ps -ef | grep ./haproxy_exporter | awk '{print $2}')"
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ubuntu@$node "rm -rf /home/ubuntu/haproxy_exporter"
    done
    ;;
  *)
    grep '#. ' $0
esac
