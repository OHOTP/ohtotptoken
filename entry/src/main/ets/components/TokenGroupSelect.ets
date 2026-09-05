import { TokenGroupState, TokenGroupStore } from 'common';
import { MaterialTheme } from './MaterialTheme';

@ComponentV2
export struct TokenGroupSelect {
  @Param groupId: string = '';
  @Event onChange: (id: string) => void = () => {};
  @Local state: TokenGroupState = TokenGroupStore.getInstance().state;

  @Computed
  get options(): SelectOption[] {
    const options: SelectOption[] = [{ value: $r('app.string.token_group_ungrouped') }];
    this.state.groups.forEach(group => options.push({ value: group.name }));
    return options;
  }

  @Computed
  get selectedIndex(): number {
    return this.state.groups.findIndex(group => group.id === this.groupId) + 1;
  }

  build() {
    Row({ space: 12 }) {
      Text($r('app.string.token_group_label'))
        .fontSize(14).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
      Select(this.options)
        .selected(this.selectedIndex)
        .value(this.selectedIndex === 0 ? $r('app.string.token_group_ungrouped') :
          this.state.groups[this.selectedIndex - 1].name)
        .onSelect((index: number) => this.onChange(index === 0 ? '' : this.state.groups[index - 1].id))
        .menuSystemMaterial(MaterialTheme.systemMaterial())
    }
    .width('100%')
    .padding(16)
  }
}
