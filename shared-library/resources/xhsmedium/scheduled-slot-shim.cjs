'use strict';

const slot = process.env.XHSMEDIUM_VALIDATION_SLOT_UTC || '';
if (!/^\d{4}-\d{2}-\d{2}T\d{2}:00:00Z$/.test(slot)) {
  throw new Error('Invalid XHSMEDIUM_VALIDATION_SLOT_UTC');
}
const RealDate = global.Date;
const fixedMs = RealDate.parse(slot);
class FixedSlotDate extends RealDate {
  constructor(...args) {
    super(...(args.length ? args : [fixedMs]));
  }
  static now() { return fixedMs; }
}
global.Date = FixedSlotDate;
delete process.env.NODE_OPTIONS;
