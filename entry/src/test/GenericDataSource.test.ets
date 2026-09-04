import { describe, it, expect } from '@ohos/hypium';
import { GenericDataSource } from 'common';

/**
 * GenericDataSource 单元测试:数据操作语义 + DataChangeListener 通知契约。
 * 监听器用记录调用的 Mock 类,验证"数据变了、通知发了、参数对了"。
 */
class RecordingListener implements DataChangeListener {
  calls: string[] = [];

  onDataReloaded(): void {
    this.calls.push('reload');
  }

  onDataAdded(index: number): void {
    this.calls.push(`added@${index}`);
  }

  onDataAdd(index: number): void {
    this.calls.push(`add@${index}`);
  }

  onDataMoved(from: number, to: number): void {
    this.calls.push(`moved#${from}->${to}`);
  }

  onDataMove(from: number, to: number): void {
    this.calls.push(`move#${from}->${to}`);
  }

  onDataDeleted(index: number): void {
    this.calls.push(`deleted@${index}`);
  }

  onDataDelete(index: number): void {
    this.calls.push(`delete@${index}`);
  }

  onDataChanged(index: number): void {
    this.calls.push(`changed@${index}`);
  }

  onDataChange(index: number): void {
    this.calls.push(`change@${index}`);
  }

  onDatasetChange(dataOperations: DataOperation[]): void {
    this.calls.push(`dataset@${dataOperations.length}`);
  }
}

export default function genericDataSourceTest() {
  describe('genericDataSourceTest', () => {
    it('initial_accessors', 0, () => {
      let ds = new GenericDataSource<string>(['a', 'b']);
      expect(ds.totalCount()).assertEqual(2);
      expect(ds.getData(0)).assertEqual('a');
      expect(ds.getData(1)).assertEqual('b');
    });

    it('addData_inserts_and_notifies', 0, () => {
      let l = new RecordingListener();
      let ds = new GenericDataSource<string>(['b']);
      ds.registerDataChangeListener(l);
      ds.addData(0, 'a');
      expect(ds.totalCount()).assertEqual(2);
      expect(ds.getData(0)).assertEqual('a');
      expect(l.calls.join('|')).assertEqual('add@0');
    });

    it('deleteData_removes_and_notifies', 0, () => {
      let l = new RecordingListener();
      let ds = new GenericDataSource<string>(['a', 'b']);
      ds.registerDataChangeListener(l);
      ds.deleteData(0);
      expect(ds.totalCount()).assertEqual(1);
      expect(ds.getData(0)).assertEqual('b');
      expect(l.calls.join('|')).assertEqual('delete@0');
    });

    it('moveData_reorders_and_notifies', 0, () => {
      let l = new RecordingListener();
      let ds = new GenericDataSource<string>(['a', 'b', 'c']);
      ds.registerDataChangeListener(l);
      ds.moveData(0, 2);
      expect(ds.getData(0)).assertEqual('b');
      expect(ds.getData(1)).assertEqual('c');
      expect(ds.getData(2)).assertEqual('a');
      expect(l.calls.join('|')).assertEqual('move#0->2');
    });

    it('updateItem_replaces_and_notifies_change', 0, () => {
      let l = new RecordingListener();
      let ds = new GenericDataSource<string>(['a', 'b']);
      ds.registerDataChangeListener(l);
      ds.updateItem(1, 'B');
      expect(ds.getData(1)).assertEqual('B');
      expect(l.calls.join('|')).assertEqual('change@1');
    });

    it('updateData_replaces_all_and_notifies_reload', 0, () => {
      let l = new RecordingListener();
      let ds = new GenericDataSource<string>(['a']);
      ds.registerDataChangeListener(l);
      ds.updateData(['x', 'y', 'z']);
      expect(ds.totalCount()).assertEqual(3);
      expect(ds.getData(2)).assertEqual('z');
      expect(l.calls.join('|')).assertEqual('reload');
    });

    it('findIndex_returns_minus_one_when_absent', 0, () => {
      let ds = new GenericDataSource<string>(['a', 'b']);
      expect(ds.findIndex((s: string): boolean => s === 'b')).assertEqual(1);
      expect(ds.findIndex((s: string): boolean => s === 'zz')).assertEqual(-1);
    });

    it('listener_registration_deduplicates', 0, () => {
      let l = new RecordingListener();
      let ds = new GenericDataSource<string>([]);
      ds.registerDataChangeListener(l);
      ds.registerDataChangeListener(l);
      ds.addData(0, 'a');
      expect(l.calls.length).assertEqual(1);
    });

    it('unregistered_listener_stops_receiving', 0, () => {
      let l1 = new RecordingListener();
      let l2 = new RecordingListener();
      let ds = new GenericDataSource<string>(['a']);
      ds.registerDataChangeListener(l1);
      ds.registerDataChangeListener(l2);
      ds.unregisterDataChangeListener(l1);
      ds.deleteData(0);
      expect(l1.calls.length).assertEqual(0);
      expect(l2.calls.join('|')).assertEqual('delete@0');
    });
  });
}
