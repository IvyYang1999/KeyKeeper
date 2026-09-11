import { selectSite, importSelected } from './import.mjs';
const siteText = document.querySelector('#site'), label = document.querySelector('#label');
const button = document.querySelector('#import'), result = document.querySelector('#result');
const messages = {
  site: '请从普通 Chrome 窗口中的 HTTPS 网站打开扩展。不支持隐身窗口。',
  denied: '已取消，没有批准这次保存。',
  changed: '原标签页已换了网站。请关闭面板，回到要保存的网站重新打开。',
  label: '请填一个简短名称，不要包含换行或密码。',
  unsupported: '这份登录态暂不支持，未导入。请保留原 Chrome 登录。',
  uncertain: '没有收到可靠的保存结果。请在 KeyKeeper「网站登录态」中核对，不要反复点击。也请确认已安装原生连接。',
  permission: '网站读取权限未能自动收回。请到 Chrome 的扩展设置收回此网站权限，并在 KeyKeeper 核对保存结果。'
};
try {
  const tabId = Number(new URL(location.href).searchParams.get('tabId'));
  const site = selectSite(await chrome.tabs.get(tabId));
  siteText.textContent = site.origin;
  label.value = site.host;
  // ActiveTab's temporary access is not a durable optional grant.
  const granted = await chrome.permissions.getAll();
  const previouslyGranted = (granted.origins ?? []).includes(site.permission.origins[0]);
  label.disabled = false; button.disabled = false;
  button.addEventListener('click', () => {
    button.disabled = true; label.disabled = true;
    button.textContent = '请在 Mac 上确认…';
    result.textContent = '这是一次性保存请求。保持面板打开，等待 KeyKeeper 的确认窗口。';
    importSelected(chrome, site, label.value, previouslyGranted).then(() => {
      button.textContent = '已保存'; result.dataset.state = 'success';
      result.textContent = '快照已保存。能否保持登录需首次打开验证；原 Chrome 登录没有改变。';
    }).catch(error => {
      button.textContent = '本次请求已结束'; result.dataset.state = 'error';
      result.textContent = messages[error?.code] ?? messages.uncertain;
    });
  }, { once: true });
} catch {
  siteText.textContent = '无法选择这个网站'; result.dataset.state = 'error'; result.textContent = messages.site;
}
