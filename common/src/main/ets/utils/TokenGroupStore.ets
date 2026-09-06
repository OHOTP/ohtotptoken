import { AppStorageV2 } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { KvManager } from './KvManager';

export const ALL_TOKEN_GROUPS: string = '__all__';
export const FAVORITE_TOKEN_GROUP: string = '__favorites__';

export class TokenGroup {
  id: string = '';
  name: string = '';
  color?: number;
  constructor(id: string, name: string, color?: number) {
    this.id = id;
    this.name = name;
    // 兼容颜色工具返回的有符号 ARGB，统一以无符号 32 位值保存。
    // 旧目录无颜色时继续使用系统强调色；忽略备份中的非法颜色。
    this.color = typeof color === 'number' && Number.isInteger(color) &&
      color >= -0x80000000 && color <= 0xFFFFFFFF ? color >>> 0 : undefined;
  }
}

@ObservedV2
export class TokenGroupState {
  @Trace groups: TokenGroup[] = [];
  @Trace selectedId: string = ALL_TOKEN_GROUPS;
}

/** 分组目录与令牌一起存入加密 KV；数组顺序就是显示顺序。 */
export class TokenGroupStore {
  private static instance: TokenGroupStore = new TokenGroupStore();
  private readonly key: string = '_token_groups_v1';
  readonly state: TokenGroupState = AppStorageV2.connect(TokenGroupState, () => new TokenGroupState())!;

  static getInstance(): TokenGroupStore {
    return TokenGroupStore.instance;
  }

  async load(): Promise<void> {
    const groups = await KvManager.getInstance().getValue<TokenGroup[]>(this.key) ?? [];
    this.state.groups = groups.map(group => new TokenGroup(group.id, group.name, group.color));
    this.reconcileSelection();
  }

  private reconcileSelection(): void {
    if (this.state.selectedId !== ALL_TOKEN_GROUPS && this.state.selectedId !== FAVORITE_TOKEN_GROUP &&
      this.state.selectedId !== '' &&
      !this.state.groups.some(group => group.id === this.state.selectedId)) {
      this.state.selectedId = ALL_TOKEN_GROUPS;
    }
  }

  private async save(groups: TokenGroup[]): Promise<void> {
    await KvManager.getInstance().setValue(this.key, groups);
    this.state.groups = groups;
    this.reconcileSelection();
  }

  isValidName(name: string, exceptId: string = ''): boolean {
    const trimmed = name.trim();
    return trimmed.length > 0 && trimmed.length <= 24 &&
      !this.state.groups.some(group => group.id !== exceptId && group.name.toLowerCase() === trimmed.toLowerCase());
  }

  async renameOrCreate(name: string, id: string = '', color?: number): Promise<void> {
    if (!this.isValidName(name, id)) {
      throw new Error('Invalid group name');
    }
    const groups = this.state.groups.map(group => new TokenGroup(group.id,
      group.id === id ? name.trim() : group.name, group.id === id ? (color ?? group.color) : group.color));
    if (id === '') {
      groups.push(new TokenGroup(util.generateRandomUUID(), name.trim(), color));
    }
    await this.save(groups);
  }

  async remove(id: string): Promise<void> {
    await this.save(this.state.groups.filter(group => group.id !== id));
  }

  async move(id: string, direction: number): Promise<void> {
    const groups = [...this.state.groups];
    const from = groups.findIndex(group => group.id === id);
    const to = from + direction;
    if (from < 0 || to < 0 || to >= groups.length) {
      return;
    }
    const group = groups[from];
    groups.splice(from, 1);
    groups.splice(to, 0, group);
    await this.save(groups);
  }

  /** 恢复采用 ID 合并，不覆盖本地目录或更改现有令牌归属。旧备份不含目录。 */
  async merge(groups: TokenGroup[] | undefined): Promise<void> {
    if (!Array.isArray(groups) || groups.length === 0) {
      return;
    }
    const merged = [...this.state.groups];
    for (const group of groups) {
      if (typeof group.id === 'string' && group.id !== '' && group.id !== ALL_TOKEN_GROUPS && group.id !== FAVORITE_TOKEN_GROUP &&
        typeof group.name === 'string' && group.name.trim().length > 0 &&
        !merged.some(existing => existing.id === group.id)) {
        merged.push(new TokenGroup(group.id, group.name.trim().slice(0, 24), group.color));
      }
    }
    await this.save(merged);
  }
}
