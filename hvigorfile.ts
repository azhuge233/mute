// @ts-nocheck – hvigor 构建脚本，不参与 ArkTS 应用代码编译
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { getNode } from '@ohos/hvigor';
import * as fs from 'fs';
import * as path from 'path';

// 本机签名配置（不入库）。存在时在构建期注入 build-profile.json5 的 signingConfigs。
const SIGNING_FILE = path.resolve(__dirname, 'signing.local.json');

function loadLocalSigning() {
  if (!fs.existsSync(SIGNING_FILE)) {
    console.warn('[signing] signing.local.json 不存在，本次构建不注入签名配置。');
    return undefined;
  }
  const config = JSON.parse(fs.readFileSync(SIGNING_FILE, 'utf-8'));
  if (!config || typeof config !== 'object' || !config.material) {
    throw new Error('[signing] signing.local.json 缺少 material 对象。');
  }
  return config;
}

const rootNode = getNode(__filename);
if (!rootNode) {
  throw new Error('[signing] 未能定位 hvigor 根节点。');
}

rootNode.afterNodeEvaluate((node) => {
  const signingConfig = loadLocalSigning();
  if (!signingConfig) {
    return;
  }
  const appContext = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
  const buildProfileOpt = appContext.getBuildProfileOpt();
  buildProfileOpt['app']['signingConfigs'] = [signingConfig];
  appContext.setBuildProfileOpt(buildProfileOpt);
  console.log('[signing] 已从 signing.local.json 注入签名配置。');
});

export default {
  system: appTasks,
  plugins: [],
};
