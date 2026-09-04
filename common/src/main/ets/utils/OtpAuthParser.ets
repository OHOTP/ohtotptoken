import { otpType, TokenConfig } from './TokenConfig';

/**
 * OtpAuthParser — otpauth:// URI 批量解析
 *
 * 从 URIConfigDialog.createTokens 抽取的纯函数,供扫码/剪贴板/URI 导入共用。
 * 不依赖 url.URL(LocalUnit 等受限环境无 URLSearchParams,见
 * openspec/changes/add-core-unit-tests/design.md 探针附录),按
 * otpauth URI 的固定结构手工切分,语义与原实现对齐:
 * - 逐条解析互不影响,单条失败仅跳过该条
 * - query 整体小写化后再取参数(secret 因此大小写不敏感)
 * - 与原实现的一处有意偏差:缺 secret 的条目不再生成空 secret 配置,而是跳过
 */

/** 单条 URI 解析结果:失败返回 undefined */
function parseOtpAuthUri(uri: string): TokenConfig | undefined {
  // 结构: otpauth://<type>/<label>?<query>
  const schemeSep = uri.indexOf('://');
  if (schemeSep < 0 || uri.slice(0, schemeSep + 1) !== 'otpauth:') {
    return undefined;
  }
  const rest = uri.slice(schemeSep + 3);
  const slashIdx = rest.indexOf('/');
  const type = (slashIdx < 0 ? rest : rest.slice(0, slashIdx)).toLowerCase();
  if (type !== 'totp' && type !== 'hotp') {
    return undefined;
  }

  // label: 首段路径,形如 Issuer:Name 或纯 Name
  const afterSlash = slashIdx < 0 ? '' : rest.slice(slashIdx + 1);
  const qIdx = afterSlash.indexOf('?');
  const path = qIdx < 0 ? afterSlash : afterSlash.slice(0, qIdx);
  const label = path.startsWith('/') ? path.slice(1) : path;

  const token = new TokenConfig();
  token.TokenType = type === 'totp' ? otpType.TOTP : otpType.HOTP;
  const labelParts = decodeURIComponent(label).split(':');
  token.TokenIssuer = labelParts[0];
  token.TokenName = labelParts[1];

  // query: 与原实现一致,整体小写化后按 & / = 切分
  const parameters: Record<string, string> = {};
  const query = qIdx < 0 ? '' : afterSlash.slice(qIdx + 1).toLowerCase();
  if (query.length > 0) {
    query.split('&').forEach((part: string) => {
      const kv: string[] = part.split('=');
      parameters[kv[0]] = kv[1];
    });
  }

  // 有意偏差:原实现会生成 secret 为空的配置,此处跳过坏输入
  const secret = parameters['secret'];
  if (!secret || secret.length === 0) {
    return undefined;
  }
  token.TokenSecret = secret;
  token.TokenPeriod = parseInt(parameters['period'] ?? '30');
  token.TokenCounter = parseInt(parameters['counter'] ?? '0');
  token.TokenDigits = parseInt(parameters['digits'] ?? '6');

  // otpauth://totp/Steam:xxx?secret=XXXXXXXXXXXXXXXXXXXXXXX&issuer=Steam
  if (token.TokenIssuer.toLowerCase() === 'steam') {
    token.TokenType = otpType.Steam;
    token.TokenAlgorithm = 'SHA1';
    token.TokenPeriod = 30;
    token.TokenDigits = 10;
  }
  return token;
}

/**
 * 批量解析 otpauth:// URI。
 * 单条非法(协议不符、类型不支持、缺 secret、格式错误)仅跳过该条,
 * 不影响其余条目的解析结果。
 */
export function parseOtpAuthUris(uris: Array<string>): Array<TokenConfig> {
  const tokens: Array<TokenConfig> = [];
  uris.forEach((uri: string) => {
    let token: TokenConfig | undefined;
    try {
      token = parseOtpAuthUri(uri);
    } catch (e) {
      // decodeURIComponent 等环节的异常按单条失败处理
      token = undefined;
    }
    if (token !== undefined) {
      tokens.push(token);
    }
  });
  return tokens;
}
