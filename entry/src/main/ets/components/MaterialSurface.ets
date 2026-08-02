import { uiMaterial } from '@kit.ArkUI';
import { MaterialPolicy } from '../utils/MaterialPolicy';
import { SETTING_GROUP_RADIUS } from './SettingStyle';

@Builder
function EmptyBuilder() {
}

/**
 * 材质厚度档位
 *
 * 与 uiMaterial.ImmersiveStyle 五档一一映射。自定义枚举而非直接暴露
 * uiMaterial.ImmersiveStyle，避免 API 23~25 设备在组件默认值求值时
 * 引用 uiMaterial 符号（低 API 设备上该符号不存在）。
 */
export enum MaterialThickness {
  ULTRA_THIN,
  THIN,
  REGULAR,
  THICK,
  ULTRA_THICK
}

/**
 * MaterialSurface — 通用沉浸材质表面容器（Phase 3.1）
 *
 * 按 MaterialPolicy.tier 三态渲染，业务布局与材质策略解耦：
 * - immersive：.systemMaterial(new uiMaterial.ImmersiveMaterial({...}))，
 *   背景强制透明（不透明背景会盖住材质层，官方 FAQ 明确）
 * - hds：通用容器没有可直接设置的 HDS 材质属性（systemMaterialEffect 仅
 *   HDS 组件可用），当前与 solid 一致走实体背景；HDS 组件（HdsNavigation/
 *   HdsTabs 等）自行通过 systemMaterialEffect 处理
 * - solid：实体背景色 + 圆角
 *
 * 材质化契约（来自官方性能规则，code review 逐条核对）：
 * 1. 内容槽子组件背景必须透明 —— 不透明背景会盖住 ImmersiveMaterial 材质层
 * 2. 禁止嵌套：同一子树仅最外层 MaterialSurface 设材质，内层不再设
 * 3. 禁止与模糊叠加：材质化后移除 backgroundBlurStyle/backgroundEffect/
 *    backdropBlur（材质自带 materialFilter 已含背景模糊）
 * 4. 禁止额外叠 shadow：需自定义阴影先把 applyShadow 置 false
 * 5. 材质参数一次性确定保持稳定，勿在运行时频繁变更
 *    （dragging 态切换属偶发，可接受）
 *
 * 兼容性：uiMaterial 符号只在 immersive 分支（API >= 26）内求值，
 * API 23~25 设备走实体背景分支，不会触碰 uiMaterial。
 */
@Preview
@ComponentV2
export struct MaterialSurface {
  /** 材质厚度，默认 REGULAR */
  @Param thickness: MaterialThickness = MaterialThickness.REGULAR;
  /** 按压弹性形变（官方 interactive，默认 false） */
  @Param interactive: boolean = false;
  /**
   * 光感交互反馈开关。官方 lightEffect 为对象类型（传对象启用/undefined 关闭），
   * 组件对外暴露 boolean，内部映射为 { color } / undefined
   */
  @Param lightEffect: boolean = false;
  /** 光感颜色，默认 Color.White（官方默认） */
  @Param lightEffectColor: ResourceColor = Color.White;
  /** 薄材质子树自动反色（THIN/ULTRA_THIN 且系统光感较强时生效），深浅色可读性用 */
  @Param colorInvert: boolean = false;
  /** 材质自带阴影，默认 true；需自定义 shadow 时置 false */
  @Param applyShadow: boolean = true;
  /** 圆角，默认与设置分组卡片一致（SettingStyle 12）；命名避开基类 borderRadius 属性方法 */
  @Param radius: Length = SETTING_GROUP_RADIUS;
  /** solid / hds 档位的实体背景色 */
  @Param solidColor: ResourceColor = $r('app.color.item_bg');
  @BuilderParam content?: CustomBuilder = EmptyBuilder;

  build() {
    if (MaterialPolicy.getInstance().isImmersive()) {
      Column() {
        if (this.content) {
          this.content();
        }
      }
        .borderRadius(this.radius)
        .backgroundColor(Color.Transparent)
        .systemMaterial(this.createImmersiveMaterial())
    } else {
      Column() {
        if (this.content) {
          this.content();
        }
      }
        .borderRadius(this.radius)
        .backgroundColor(this.solidColor)
    }
  }

  /**
   * 构造 ImmersiveMaterial。仅在 immersive 分支（API >= 26）调用，
   * uiMaterial 符号不会在低 API 设备上求值。
   */
  private createImmersiveMaterial(): uiMaterial.Material {
    return new uiMaterial.ImmersiveMaterial({
      style: this.mapThickness(this.thickness),
      interactive: this.interactive,
      lightEffect: this.lightEffect ? { color: this.lightEffectColor } : undefined,
      colorInvert: this.colorInvert,
      applyShadow: this.applyShadow
    });
  }

  /** MaterialThickness → uiMaterial.ImmersiveStyle（仅 immersive 分支调用） */
  private mapThickness(thickness: MaterialThickness): uiMaterial.ImmersiveStyle {
    switch (thickness) {
      case MaterialThickness.ULTRA_THIN:
        return uiMaterial.ImmersiveStyle.ULTRA_THIN;
      case MaterialThickness.THIN:
        return uiMaterial.ImmersiveStyle.THIN;
      case MaterialThickness.THICK:
        return uiMaterial.ImmersiveStyle.THICK;
      case MaterialThickness.ULTRA_THICK:
        return uiMaterial.ImmersiveStyle.ULTRA_THICK;
      case MaterialThickness.REGULAR:
      default:
        return uiMaterial.ImmersiveStyle.REGULAR;
    }
  }
}
