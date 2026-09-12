import { describe, it, expect } from '@ohos/hypium';
import { TokenConfig } from 'common';
import { TokenImporterRegistry } from 'common';
import { URIImporter } from 'common';

/**
 * 导入器注册表测试：注册顺序、幂等 init、同 id 覆盖与 URI 导入器的空实现契约。
 */
export default function tokenImporterRegistryTest() {
  describe('tokenImporterRegistryTest', () => {
    it('init_registers_builtin_importers_in_order', 0, () => {
      const registry = TokenImporterRegistry.getInstance();
      registry.init();

      const all = registry.getAll();
      expect(all.length >= 2).assertTrue();
      expect(all[0].id).assertEqual('twofa');
      expect(all[1].id).assertEqual('uri');
    });

    it('init_is_idempotent_no_duplicate_registration', 0, () => {
      const registry = TokenImporterRegistry.getInstance();
      registry.init();
      registry.init();
      registry.init();

      const ids = registry.getAll().map(i => i.id);
      const unique = new Set<string>(ids);
      expect(unique.size).assertEqual(ids.length);
    });

    it('register_same_id_overwrites_previous_entry', 0, () => {
      const registry = TokenImporterRegistry.getInstance();
      const before = registry.getAll().length;

      const custom = new URIImporter();
      registry.register(custom);

      expect(registry.getAll().length).assertEqual(before);
      expect(registry.getAll()[registry.getAll().length - 1] === custom).assertTrue();
    });

    it('uri_importer_contract_and_noop_import', 0, () => {
      const importer = new URIImporter();
      expect(importer.id).assertEqual('uri');
      expect(importer.name !== undefined).assertTrue();
      expect(importer.description !== undefined).assertTrue();
      expect(importer.icon !== undefined).assertTrue();

      // 实际对话框由 BackupAndMigrationSheet 负责，import() 必须是无副作用空操作
      let called = false;
      importer.import(undefined as ESObject as UIContext,
        (_tokens: Array<TokenConfig>) => {
          called = true;
        });
      expect(called).assertFalse();
    });
  });
}
