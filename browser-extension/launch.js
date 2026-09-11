// A small persistent window, not an action popup: native approval must not destroy the sender.
chrome.action.onClicked.addListener(tab => {
  if (!Number.isInteger(tab.id)) return;
  chrome.windows.create({ url: chrome.runtime.getURL(`popup.html?tabId=${tab.id}`),
    type: 'popup', width: 400, height: 680 }).catch(() => {});
});
