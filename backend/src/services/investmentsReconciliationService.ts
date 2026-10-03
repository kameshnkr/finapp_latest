// Pure, DB-free reconciliation logic — kept separate and side-effect-free so
// it's directly unit-testable (see scripts/investmentsReconciliationTest.ts).

export type ReconciliationInput = {
  accountAssetId: string;
  isin: string;
  assetName: string;
  /** Units already on record in investments_positions before this upload. */
  existingUnits: number;
  /** Sum of new BUY units for this asset parsed from this upload's Trade Book. */
  buyUnits: number;
  /** Sum of new SELL units for this asset parsed from this upload's Trade Book. */
  sellUnits: number;
  /** Units reported for this asset in the Holdings file. null = asset not listed there (treated as 0). */
  holdingsUnits: number | null;
  /** Price reported for this asset in the Holdings file, if any — used only
   * as the price for a proposed reconciliation dummy trade, never written
   * to the global latest-price tables. */
  holdingsPrice: number | null;
};

export type ReconciliationMismatch = {
  accountAssetId: string;
  isin: string;
  assetName: string;
  existingUnits: string;
  buyUnits: string;
  sellUnits: string;
  expectedUnits: string;
  holdingsUnits: string;
  dummyType: "BUY" | "SELL";
  dummyUnits: string;
  dummyPrice: string | null;
  /** false when no price is available anywhere to construct a valid dummy
   * trade row (price is NOT NULL in the schema) — the UI must disable the
   * "create reconciliation" option and only offer "skip" in that case. */
  canCreateDummy: boolean;
};

// Units below this are treated as float noise, not a genuine mismatch.
const UNITS_EPSILON = 0.001;

export function reconcileAssetPositions(inputs: ReconciliationInput[]): ReconciliationMismatch[] {
  const mismatches: ReconciliationMismatch[] = [];

  for (const inp of inputs) {
    const expectedUnits = inp.existingUnits + inp.buyUnits - inp.sellUnits;
    const holdingsUnits = inp.holdingsUnits ?? 0;
    const delta = holdingsUnits - expectedUnits;

    if (Math.abs(delta) <= UNITS_EPSILON) continue;

    const dummyType: "BUY" | "SELL" = delta > 0 ? "BUY" : "SELL";
    const dummyUnits = Math.abs(delta);
    const dummyPrice = inp.holdingsPrice;

    mismatches.push({
      accountAssetId: inp.accountAssetId,
      isin: inp.isin,
      assetName: inp.assetName,
      existingUnits: inp.existingUnits.toFixed(6),
      buyUnits: inp.buyUnits.toFixed(6),
      sellUnits: inp.sellUnits.toFixed(6),
      expectedUnits: expectedUnits.toFixed(6),
      holdingsUnits: holdingsUnits.toFixed(6),
      dummyType,
      dummyUnits: dummyUnits.toFixed(6),
      dummyPrice: dummyPrice !== null ? dummyPrice.toFixed(4) : null,
      canCreateDummy: dummyPrice !== null,
    });
  }

  return mismatches;
}
