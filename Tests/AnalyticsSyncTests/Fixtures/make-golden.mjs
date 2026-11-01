// Independent reference implementation (Node, no dependencies) of the
// CostcoTracker → Analytics Export V1 mapping and ID derivation.
//
// It exists so the Swift implementation is checked against a second,
// separately written implementation rather than against itself:
//
//   node Tests/AnalyticsSyncTests/Fixtures/make-golden.mjs
//
// writes expected-export-v1.json and id-vectors.json next to this file. The
// Swift tests require AnalyticsExportBuilder to reproduce both exactly. The
// golden export was also validated with the CostcoTracker Analytics importer
// (importExportText) when it was generated.
import { createHmac } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const source = JSON.parse(readFileSync(join(here, 'source-snapshot.json'), 'utf8'))

// 32 bytes 0x00…0x1f, base64url without padding — the server's idKey format.
export const ID_KEY = Buffer.from([...Array(32).keys()]).toString('base64url')
const keyBytes = Buffer.from(ID_KEY, 'base64url')

export function token(domain, ...parts) {
  const message = [domain, ...parts].join('\u0000')
  return createHmac('sha256', keyBytes).update(message, 'utf8').digest('base64url').slice(0, 22)
}

const ids = {
  receipt: (barcode) => `r_${token('receipt', barcode)}`,
  item: (barcode, itemNumber, occurrence) => `i_${token('item', barcode, itemNumber, String(occurrence))}`,
  return: (txn, itemNumber) => `ret_${token('return', txn, itemNumber)}`,
  adjustment: (txn, itemNumber) => `adj_${token('adjustment', txn, itemNumber)}`,
  transaction: (txn) => `t_${token('transaction', txn)}`,
}

const roundHalfAwayFromZero = (v) => Math.sign(v) * Math.round(Math.abs(v))
const cents = (v) => roundHalfAwayFromZero(v * 100)
const isFiniteNumber = (v) => typeof v === 'number' && Number.isFinite(v)
const text = (v) => (v === null || v === undefined || v.trim() === '' ? null : v)
const isBlank = (v) => v === null || v === undefined || v.trim() === ''

function calendarDate(v) {
  if (typeof v !== 'string') return null
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v)
  if (!m) return null
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])]
  if (mo < 1 || mo > 12 || d < 1) return null
  return d <= new Date(Date.UTC(y, mo, 0)).getUTCDate() ? v : null
}

const exclusions = {}
const exclude = (reason) => (exclusions[reason] = (exclusions[reason] ?? 0) + 1)

// Receipts
const receipts = []
const receiptIdByBarcode = new Map()
for (const r of source.receipts) {
  if (isBlank(r.barcode)) {
    exclude('receipt.missingKey')
    continue
  }
  const online = (r.warehouse ?? '').startsWith('Online Order')
  const identifierKind = online ? 'onlineOrderKey' : r.barcode.startsWith('WHSE_') ? 'synthesizedWarehouseKey' : 'transactionBarcode'
  const id = ids.receipt(r.barcode)
  receiptIdByBarcode.set(r.barcode, id)
  receipts.push({
    id,
    sourceType: online ? 'online' : 'warehouse',
    identifierKind,
    purchaseDate: calendarDate(r.date),
    warehouse: text(r.warehouse),
  })
}

// Items (occurrence counted over all rows of the receipt with that item number, by rowid)
const items = []
const occurrences = new Map()
for (const it of [...source.items].sort((a, b) => a.id - b.id)) {
  const key = `${it.receipt_barcode}\u0000${it.item_number}`
  const occurrence = occurrences.get(key) ?? 0
  occurrences.set(key, occurrence + 1)
  const purchaseId = receiptIdByBarcode.get(it.receipt_barcode)
  if (!purchaseId) { exclude('item.orphan'); continue }
  if (isBlank(it.item_number)) { exclude('item.missingItemNumber'); continue }
  if (!isFiniteNumber(it.quantity) || it.quantity <= 0) { exclude('item.invalidQuantity'); continue }
  if (!isFiniteNumber(it.unit_price) || it.unit_price < 0) { exclude('item.invalidPrice'); continue }
  const unitCentsRaw = it.unit_price * 100
  const unitPriceCents = Math.abs(unitCentsRaw - Math.round(unitCentsRaw)) < 1e-6 ? roundHalfAwayFromZero(unitCentsRaw) : null
  items.push({
    id: ids.item(it.receipt_barcode, it.item_number, occurrence),
    purchaseId,
    itemNumber: it.item_number,
    description: it.description ?? '',
    quantity: it.quantity,
    lineTotalCents: roundHalfAwayFromZero(it.unit_price * it.quantity * 100),
    unitPriceCents,
  })
}

// Returns and adjustments, grouped per transaction
const groups = new Map()
const group = (txn) => {
  if (!groups.has(txn)) groups.set(txn, { returns: [], adjustments: [] })
  return groups.get(txn)
}
for (const r of source.item_returns) {
  if (isBlank(r.transaction_barcode) || isBlank(r.item_number)) { exclude('return.missingKey'); continue }
  if (!isFiniteNumber(r.returned_quantity) || r.returned_quantity <= 0) { exclude('return.invalidQuantity'); continue }
  if (r.merchandise_amount !== null && r.merchandise_amount < 0) { exclude('return.invalidAmount'); continue }
  group(r.transaction_barcode).returns.push({
    id: ids.return(r.transaction_barcode, r.item_number),
    transactionId: ids.transaction(r.transaction_barcode),
    itemNumber: r.item_number,
    returnDate: calendarDate(r.return_date),
    warehouse: text(r.warehouse),
    quantity: r.returned_quantity,
    description: text(r.description),
    transactionType: text(r.transaction_type),
    merchandiseAmountCents: r.merchandise_amount === null ? null : cents(r.merchandise_amount),
    transactionTotalCents: r.transaction_total === null ? null : cents(r.transaction_total),
    sourcePurchaseId: null,
  })
}
for (const a of source.price_adjustments) {
  if (isBlank(a.transaction_barcode) || isBlank(a.item_number)) { exclude('adjustment.missingKey'); continue }
  if (!isFiniteNumber(a.adjustment_amount) || a.adjustment_amount < 0) { exclude('adjustment.invalidAmount'); continue }
  if (!isFiniteNumber(a.transaction_total)) { exclude('adjustment.missingTransactionTotal'); continue }
  group(a.transaction_barcode).adjustments.push({
    id: ids.adjustment(a.transaction_barcode, a.item_number),
    transactionId: ids.transaction(a.transaction_barcode),
    itemNumber: a.item_number,
    adjustmentDate: calendarDate(a.adjustment_date),
    warehouse: text(a.warehouse),
    amountCents: cents(a.adjustment_amount),
    adjustedQuantity: isFiniteNumber(a.adjusted_quantity) && a.adjusted_quantity > 0 ? a.adjusted_quantity : null,
    referenceLineNumbers: (a.reference_line_number ?? '').split(',').map((s) => s.trim()).filter((s) => s !== ''),
    transactionType: text(a.transaction_type),
    transactionTotalCents: cents(a.transaction_total),
    sourcePurchaseId: null,
  })
}
const returns = []
const priceAdjustments = []
for (const g of groups.values()) {
  const rows = [
    ...g.returns.map((r) => [r.returnDate, r.warehouse, r.transactionType, r.transactionTotalCents]),
    ...g.adjustments.map((a) => [a.adjustmentDate, a.warehouse, a.transactionType, a.transactionTotalCents]),
  ].map((x) => JSON.stringify(x))
  if (new Set(rows).size > 1) {
    for (let i = 0; i < g.returns.length + g.adjustments.length; i++) exclude('transaction.inconsistent')
    continue
  }
  returns.push(...g.returns)
  priceAdjustments.push(...g.adjustments)
}

const byId = (a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
const exportV1 = {
  format: 'costcotracker-analytics',
  formatVersion: 1,
  exportedAt: '2026-11-01T12:00:00Z',
  currency: 'USD',
  receipts: receipts.sort(byId),
  items: items.sort(byId),
  returns: returns.sort(byId),
  priceAdjustments: priceAdjustments.sort(byId),
}
writeFileSync(join(here, 'expected-export-v1.json'), JSON.stringify({ export: exportV1, exclusions }, null, 2) + '\n')

const vectors = {
  idKey: ID_KEY,
  hmacKeyHex: keyBytes.toString('hex'),
  vectors: [
    { kind: 'receipt', parts: ['99990000000000000001'], expected: ids.receipt('99990000000000000001') },
    { kind: 'receipt', parts: ['WHSE_2026-01-18_SYNTHETIC_SOUTH'], expected: ids.receipt('WHSE_2026-01-18_SYNTHETIC_SOUTH') },
    { kind: 'receipt', parts: ['SYNTH-ORD-1001'], expected: ids.receipt('SYNTH-ORD-1001') },
    { kind: 'item', parts: ['SYNTH-ORD-1001', '9000005', '0'], expected: ids.item('SYNTH-ORD-1001', '9000005', 0) },
    { kind: 'item', parts: ['SYNTH-ORD-1001', '9000005', '1'], expected: ids.item('SYNTH-ORD-1001', '9000005', 1) },
    { kind: 'return', parts: ['99990000000000000101', '9000005'], expected: ids.return('99990000000000000101', '9000005') },
    { kind: 'adjustment', parts: ['99990000000000000101', '9000005'], expected: ids.adjustment('99990000000000000101', '9000005') },
    { kind: 'transaction', parts: ['99990000000000000101'], expected: ids.transaction('99990000000000000101') },
    { kind: 'receipt', parts: ['ünïcødé ✓'], expected: ids.receipt('ünïcødé ✓') },
  ],
  // Raw HMAC check independent of the ID format: base64url(HMAC(key, "receipt\0abc")) in full.
  rawHmac: { message: 'receipt\u0000abc', base64url: createHmac('sha256', keyBytes).update('receipt\u0000abc').digest('base64url') },
}
writeFileSync(join(here, 'id-vectors.json'), JSON.stringify(vectors, null, 2) + '\n')
console.log('exclusions', exclusions)
console.log('counts', { receipts: receipts.length, items: items.length, returns: returns.length, priceAdjustments: priceAdjustments.length })
