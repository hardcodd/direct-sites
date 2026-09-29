const configuration = {
  value: {
    mode: "pac_script",
    pacScript: {
      url: "http://127.0.0.1:17879/proxy.pac",
      mandatory: true
    }
  },
  scope: "regular"
};

function configureProxy() {
  chrome.proxy.settings.set(configuration, () => {
    if (chrome.runtime.lastError) {
      console.error("Direct Sites proxy setup failed:", chrome.runtime.lastError.message);
    }
  });
}

chrome.runtime.onInstalled.addListener(configureProxy);
chrome.runtime.onStartup.addListener(configureProxy);
