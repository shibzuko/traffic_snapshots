curl -fsSL https://raw.githubusercontent.com/shibzuko/traffic_snapshots/master/install_agent.sh \
  -o /tmp/install_agent.sh && \
sudo bash /tmp/install_agent.sh \
  --endpoint https://my-panel.com/tracking/api/v1/node-snapshots/ingest/
