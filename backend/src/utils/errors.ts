export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
    public code?: string
  ) {
    super(message);
    this.name = "HttpError";
  }
}

export function assertUserResource<T extends { user_id: bigint } | null>(
  row: T,
  userId: bigint
): asserts row is NonNullable<T> {
  if (!row || row.user_id !== userId) {
    throw new HttpError(404, "Not found");
  }
}
