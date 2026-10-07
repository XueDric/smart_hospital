import { describe, it, expect } from '@ohos/hypium';
import { formatYmd, formatYmdHm } from '../main/ets/util/DateFmt';

export default function dateFmtTest() {
  describe('DateFmt', () => {
    it('formatYmd_padsMonthAndDay', 0, () => {
      expect(formatYmd(new Date(2026, 0, 5))).assertEqual('2026-01-05');
      expect(formatYmd(new Date(2026, 8, 9))).assertEqual('2026-09-09');
    });

    it('formatYmd_keepsTwoDigitParts', 0, () => {
      expect(formatYmd(new Date(2026, 11, 31))).assertEqual('2026-12-31');
    });

    it('formatYmdHm_padsTimeAndAppendsSeconds', 0, () => {
      expect(formatYmdHm(new Date(2026, 8, 9), 7, 8)).assertEqual('2026-09-09T07:08:00');
      expect(formatYmdHm(new Date(2026, 11, 31), 23, 59)).assertEqual('2026-12-31T23:59:00');
    });

    it('formatYmdHm_handlesMidnight', 0, () => {
      expect(formatYmdHm(new Date(2026, 0, 1), 0, 0)).assertEqual('2026-01-01T00:00:00');
    });
  });
}
