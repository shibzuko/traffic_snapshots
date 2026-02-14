curl -fsSL https://raw.githubusercontent.com/shibzuko/traffic_snapshots/master/install_agent.sh \
  -o /tmp/install_agent.sh && \
sudo bash /tmp/install_agent.sh \
  --domain node231.com \
  --endpoint https://my-panel.com/api/ingest
