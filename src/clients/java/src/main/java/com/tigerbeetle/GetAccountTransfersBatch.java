//////////////////////////////////////////////////////////
// This file was auto-generated by java_bindings.zig
// Do not manually modify.
//////////////////////////////////////////////////////////

package com.tigerbeetle;

import java.nio.ByteBuffer;


final class GetAccountTransfersBatch extends Batch {

    interface Struct {
        int SIZE = 64;

        int AccountId = 0;
        int TimestampMin = 16;
        int TimestampMax = 24;
        int Limit = 32;
        int Flags = 36;
        int Reserved = 40;
    }

    static final GetAccountTransfersBatch EMPTY = new GetAccountTransfersBatch(0);

    /**
     * Creates an empty batch with the desired maximum capacity.
     * <p>
     * Once created, an instance cannot be resized, however it may contain any number of elements
     * between zero and its {@link #getCapacity capacity}.
     *
     * @param capacity the maximum capacity.
     * @throws IllegalArgumentException if capacity is negative.
     */
    public GetAccountTransfersBatch(final int capacity) {
        super(capacity, Struct.SIZE);
    }

    GetAccountTransfersBatch(final ByteBuffer buffer) {
        super(buffer, Struct.SIZE);
    }

    /**
     * @return an array of 16 bytes representing the 128-bit value.
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     */
    public byte[] getAccountId() {
        return getUInt128(at(Struct.AccountId));
    }

    /**
     * @param part a {@link UInt128} enum indicating which part of the 128-bit value is to be retrieved.
     * @return a {@code long} representing the first 8 bytes of the 128-bit value if
     *         {@link UInt128#LeastSignificant} is informed, or the last 8 bytes if
     *         {@link UInt128#MostSignificant}.
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     */
    public long getAccountId(final UInt128 part) {
        return getUInt128(at(Struct.AccountId), part);
    }

    /**
     * @param accountId an array of 16 bytes representing the 128-bit value.
     * @throws IllegalArgumentException if {@code accountId} is not 16 bytes long.
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     * @throws IllegalStateException if a {@link #isReadOnly() read-only} batch.
     */
    public void setAccountId(final byte[] accountId) {
        putUInt128(at(Struct.AccountId), accountId);
    }

    /**
     * @param leastSignificant a {@code long} representing the first 8 bytes of the 128-bit value.
     * @param mostSignificant a {@code long} representing the last 8 bytes of the 128-bit value.
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     * @throws IllegalStateException if a {@link #isReadOnly() read-only} batch.
     */
    public void setAccountId(final long leastSignificant, final long mostSignificant) {
        putUInt128(at(Struct.AccountId), leastSignificant, mostSignificant);
    }

    /**
     * @param leastSignificant a {@code long} representing the first 8 bytes of the 128-bit value.
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     * @throws IllegalStateException if a {@link #isReadOnly() read-only} batch.
     */
    public void setAccountId(final long leastSignificant) {
        putUInt128(at(Struct.AccountId), leastSignificant, 0);
    }

    /**
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     */
    public long getTimestampMin() {
        final var value = getUInt64(at(Struct.TimestampMin));
        return value;
    }

    /**
     * @param timestampMin
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     * @throws IllegalStateException if a {@link #isReadOnly() read-only} batch.
     */
    public void setTimestampMin(final long timestampMin) {
        putUInt64(at(Struct.TimestampMin), timestampMin);
    }

    /**
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     */
    public long getTimestampMax() {
        final var value = getUInt64(at(Struct.TimestampMax));
        return value;
    }

    /**
     * @param timestampMax
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     * @throws IllegalStateException if a {@link #isReadOnly() read-only} batch.
     */
    public void setTimestampMax(final long timestampMax) {
        putUInt64(at(Struct.TimestampMax), timestampMax);
    }

    /**
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     */
    public int getLimit() {
        final var value = getUInt32(at(Struct.Limit));
        return value;
    }

    /**
     * @param limit
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     * @throws IllegalStateException if a {@link #isReadOnly() read-only} batch.
     */
    public void setLimit(final int limit) {
        putUInt32(at(Struct.Limit), limit);
    }

    /**
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     */
    public int getFlags() {
        final var value = getUInt32(at(Struct.Flags));
        return value;
    }

    /**
     * @param flags
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     * @throws IllegalStateException if a {@link #isReadOnly() read-only} batch.
     */
    public void setFlags(final int flags) {
        putUInt32(at(Struct.Flags), flags);
    }

    /**
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     */
    byte[] getReserved() {
        return getArray(at(Struct.Reserved), 24);
    }

    /**
     * @param reserved
     * @throws IllegalStateException if not at a {@link #isValidPosition valid position}.
     * @throws IllegalStateException if a {@link #isReadOnly() read-only} batch.
     */
    void setReserved(byte[] reserved) {
        if (reserved == null)
            reserved = new byte[24];
        if (reserved.length != 24)
            throw new IllegalArgumentException("Reserved must be 24 bytes long");
        putArray(at(Struct.Reserved), reserved);
    }

}

