/**
 * 日志脱敏（收窄版）。
 *
 * 与 Dart 侧 `lib/utils/log_redactor.dart` 保持同一套规则：
 * **只遮蔽 LunaTV 服务器地址与账号密码类凭据**，其它地址一律保留。
 *
 * ArkTS 侧只用在这里给**原生日志**（mpv / avplayer 经 onLogMessage 输出到
 * hilog 的那些行）做脱敏 —— Dart 侧的落盘日志由 AppLogger 统一脱敏。
 *
 * 规则：
 *  - **已登记的 LunaTV 服务器地址**（由 Dart 侧 LogRedactor.registerServerAddress
 *    收集，随 open 调用下发）：出现即替换为 ***；
 *  - URL 中的 `user:pass@`：userinfo 替换为 ***@，保留 scheme 与 host；
 *  - 凭据类键值对（password / username / token / cookie 等）值替换为 ***。
 *
 * **不遮蔽**：媒体流地址、第三方接口地址、裸 IP、裸域名 —— 排障需要看到它们。
 */
export class LogRedactor {
  /** 遮蔽占位符。 */
  static readonly MASK: string = '***';

  /** 已登记的敏感 host（不含端口），由 Dart 侧下发。 */
  private static sensitiveHosts: string[] = [];

  /** 记录 Dart 侧下发的敏感 host 列表。 */
  static setSensitiveHosts(hosts: string[] | undefined | null): void {
    if (!hosts || hosts.length === 0) {
      LogRedactor.sensitiveHosts = [];
      return;
    }
    const list: string[] = [];
    hosts.forEach((h: string) => {
      const v = h.trim();
      if (v.length > 0 && list.indexOf(v) < 0) {
        list.push(v);
      }
    });
    LogRedactor.sensitiveHosts = list;
  }

  private static readonly USERINFO_RE: RegExp = new RegExp(
    "([a-zA-Z][a-zA-Z0-9+.\\-]*://)([^\\s/?#@'\"]*@)",
    'g',
  );

  private static readonly CRED_RE: RegExp = new RegExp(
    "([\"']?\\b(?:password|passwd|pwd|username|user_name|token|access_token|cookie|set-cookie|authorization|secret|api_key|apikey)\\b[\"']?\\s*[:=]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s,;&}\\]]+)",
    'gi',
  );

  /** 对一段文本做脱敏。 */
  static redact(text: string): string {
    if (!text) {
      return text;
    }
    let out: string = LogRedactor.maskHosts(text);
    out = LogRedactor.maskUserInfo(out);
    out = LogRedactor.maskCredentials(out);
    return out;
  }

  /** 遮蔽已登记的 LunaTV 服务器地址。 */
  private static maskHosts(text: string): string {
    if (LogRedactor.sensitiveHosts.length === 0) {
      return text;
    }
    let out: string = text;
    LogRedactor.sensitiveHosts.forEach((host: string) => {
      out = out.split(host).join(LogRedactor.MASK);
    });
    return out;
  }

  /** 遮蔽 URL 中的 userinfo（保留 scheme 与 host）。 */
  private static maskUserInfo(text: string): string {
    const re = new RegExp(LogRedactor.USERINFO_RE.source, 'g');
    let result: string = '';
    let last: number = 0;
    let m: RegExpExecArray | null = re.exec(text);
    while (m !== null) {
      const scheme: string = m[1] ?? '';
      result += text.substring(last, m.index) + scheme + LogRedactor.MASK + '@';
      last = m.index + m[0].length;
      m = re.exec(text);
    }
    result += text.substring(last);
    return result;
  }

  /** 遮蔽凭据类键值对的值。 */
  private static maskCredentials(text: string): string {
    const re = new RegExp(LogRedactor.CRED_RE.source, 'gi');
    let result: string = '';
    let last: number = 0;
    let m: RegExpExecArray | null = re.exec(text);
    while (m !== null) {
      const key: string = m[1] ?? '';
      const val: string = m[2] ?? '';
      let kept: string = LogRedactor.MASK;
      if (val.startsWith('"')) {
        kept = '"' + LogRedactor.MASK + '"';
      } else if (val.startsWith("'")) {
        kept = "'" + LogRedactor.MASK + "'";
      }
      result += text.substring(last, m.index) + key + kept;
      last = m.index + m[0].length;
      m = re.exec(text);
    }
    result += text.substring(last);
    return result;
  }
}
