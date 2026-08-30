import { systemDateTime } from '@kit.BasicServicesKit';
import { FrameCallback, UIContext } from '@kit.ArkUI';
import { hilog, hiTraceMeter } from '@kit.PerformanceAnalysisKit';
import { TokenConfig } from 'common';

const DOMAIN: number = 0xFF00;
const TAG: string = 'TokenSwitchPerf';
const TRACE_NAME: string = 'H:tokenSwitch.routeReady';

/** 单次宽屏令牌切换的关联信息。仅记录 UUID 后缀，不记录令牌名称或密钥。 */
export class TokenSwitchTrace {
  requestId: number;
  startedAtMs: number;
  lastStageAtMs: number;
  tokenIdSuffix: string;
  route: string;
  routeTraceFinished: boolean = false;

  constructor(requestId: number, startedAtMs: number, tokenIdSuffix: string, route: string) {
    this.requestId = requestId;
    this.startedAtMs = startedAtMs;
    this.lastStageAtMs = startedAtMs;
    this.tokenIdSuffix = tokenIdSuffix;
    this.route = route;
  }
}

class TokenSwitchIdleCallback extends FrameCallback {
  private trace: TokenSwitchTrace;

  constructor(trace: TokenSwitchTrace) {
    super();
    this.trace = trace;
  }

  onIdle(_: number): void {
    TokenSwitchPerf.mark(this.trace, 'frameIdle');
  }
}

/**
 * 宽屏令牌切换诊断打点。
 * 日志筛选关键字：TokenSwitchPerf；Profiler Trace 名称：H:tokenSwitch.routeReady。
 */
export class TokenSwitchPerf {
  private static requestSequence: number = 0;
  private static pendingTrace?: TokenSwitchTrace = undefined;

  private static nowMs(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, false);
  }

  static begin(tokenUuid: string, route: string): TokenSwitchTrace {
    if (TokenSwitchPerf.pendingTrace !== undefined &&
      !TokenSwitchPerf.pendingTrace.routeTraceFinished) {
      TokenSwitchPerf.mark(TokenSwitchPerf.pendingTrace, 'superseded');
      TokenSwitchPerf.finishRouteTrace(TokenSwitchPerf.pendingTrace);
    }
    const now = TokenSwitchPerf.nowMs();
    const trace = new TokenSwitchTrace(
      ++TokenSwitchPerf.requestSequence,
      now,
      tokenUuid.slice(Math.max(0, tokenUuid.length - 8)),
      route
    );
    TokenSwitchPerf.pendingTrace = trace;
    hiTraceMeter.startTrace(TRACE_NAME, trace.requestId);
    TokenSwitchPerf.log(trace, 'click', now, 0);
    return trace;
  }

  static mark(trace: TokenSwitchTrace | undefined, stage: string): void {
    if (trace === undefined) {
      return;
    }
    const now = TokenSwitchPerf.nowMs();
    const stageMs = now - trace.lastStageAtMs;
    trace.lastStageAtMs = now;
    TokenSwitchPerf.log(trace, stage, now, stageMs);
  }

  static routeReady(trace: TokenSwitchTrace | undefined, uiContext: UIContext): void {
    if (trace === undefined) {
      return;
    }
    TokenSwitchPerf.mark(trace, 'routeReady');
    TokenSwitchPerf.finishRouteTrace(trace);
    uiContext.postFrameCallback(new TokenSwitchIdleCallback(trace));
  }

  static reusedReady(trace: TokenSwitchTrace | undefined, uiContext: UIContext): void {
    if (trace === undefined) {
      return;
    }
    TokenSwitchPerf.mark(trace, 'stateApplied');
    TokenSwitchPerf.finishRouteTrace(trace);
    uiContext.postFrameCallback(new TokenSwitchIdleCallback(trace));
  }

  private static finishRouteTrace(trace: TokenSwitchTrace): void {
    if (trace.routeTraceFinished) {
      return;
    }
    trace.routeTraceFinished = true;
    hiTraceMeter.finishTrace(TRACE_NAME, trace.requestId);
    if (TokenSwitchPerf.pendingTrace?.requestId === trace.requestId) {
      TokenSwitchPerf.pendingTrace = undefined;
    }
  }

  private static log(trace: TokenSwitchTrace, stage: string, now: number, stageMs: number): void {
    hilog.info(DOMAIN, TAG,
      'id=%{public}d stage=%{public}s totalMs=%{public}d stageMs=%{public}d token=%{public}s route=%{public}s',
      trace.requestId, stage, now - trace.startedAtMs, stageMs, trace.tokenIdSuffix, trace.route);
  }
}

/** 保存宽屏稳定详情页当前应展示的数据，避免首次路由尚未创建时丢失快速选择事件。 */
export class ResponsiveTokenEditStore {
  private static instance: ResponsiveTokenEditStore;
  private config?: TokenConfig = undefined;
  private trace?: TokenSwitchTrace = undefined;

  static getInstance(): ResponsiveTokenEditStore {
    if (ResponsiveTokenEditStore.instance === undefined) {
      ResponsiveTokenEditStore.instance = new ResponsiveTokenEditStore();
    }
    return ResponsiveTokenEditStore.instance;
  }

  select(config: TokenConfig, trace: TokenSwitchTrace): void {
    this.config = config;
    this.trace = trace;
  }

  currentConfig(): TokenConfig | undefined {
    return this.config;
  }

  currentTrace(): TokenSwitchTrace | undefined {
    return this.trace;
  }
}
