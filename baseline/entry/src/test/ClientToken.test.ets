import { describe, it, expect } from '@ohos/hypium';
import { genClientToken } from '../main/ets/util/ClientToken';

const HYPHEN_POSITIONS: number[] = [8, 13, 18, 23];
const HEX_CHARS = '0123456789abcdef';
const VARIANT_CHARS = '89ab';

function isHyphenPosition(index: number): boolean {
  return HYPHEN_POSITIONS.indexOf(index) >= 0;
}

function expectUuidV4(token: string): void {
  expect(token.length).assertEqual(36);

  for (let i = 0; i < token.length; i++) {
    const ch = token.charAt(i);
    if (isHyphenPosition(i)) {
      expect(ch).assertEqual('-');
    } else {
      expect(HEX_CHARS.indexOf(ch) >= 0).assertTrue();
    }
  }

  expect(token.charAt(14)).assertEqual('4');
  expect(VARIANT_CHARS.indexOf(token.charAt(19)) >= 0).assertTrue();
}

export default function clientTokenTest() {
  describe('ClientToken', () => {
    it('genClientToken_returnsUuidV4Shape', 0, () => {
      expectUuidV4(genClientToken());
    });

    it('genClientToken_generatesDistinctTokens', 0, () => {
      const tokens: string[] = [];
      for (let i = 0; i < 64; i++) {
        tokens.push(genClientToken());
      }

      const unique = new Set<string>(tokens);
      expect(unique.size).assertEqual(tokens.length);
    });
  });
}
