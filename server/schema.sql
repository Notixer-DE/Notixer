CREATE TABLE accounts (
    id uuid PRIMARY KEY,
    cursor bigint NOT NULL DEFAULT 0 CHECK (cursor >= 0),
    used_bytes bigint NOT NULL DEFAULT 0 CHECK (used_bytes >= 0),
    quota_bytes bigint NOT NULL DEFAULT 107374182400 CHECK (quota_bytes > 0),
    revision_count bigint NOT NULL DEFAULT 0,
    max_revisions bigint NOT NULL DEFAULT 1000000,
    key_check text
);
CREATE TABLE devices (
    id uuid PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts(id),
    token_hash text NOT NULL UNIQUE,
    revoked boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX devices_account ON devices(account_id);
CREATE TABLE blobs (
    account_id uuid NOT NULL REFERENCES accounts(id),
    id text NOT NULL CHECK (id ~ '^[0-9a-f]{64}$'),
    bytes bigint NOT NULL CHECK (bytes BETWEEN 28 AND 4194332),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(account_id, id)
);
CREATE TABLE revisions (
    account_id uuid NOT NULL REFERENCES accounts(id),
    id text NOT NULL CHECK (id ~ '^[0-9a-f]{64}$'),
    seq bigint NOT NULL,
    envelope jsonb NOT NULL,
    device_id uuid NOT NULL REFERENCES devices(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(account_id, id),
    UNIQUE(account_id, seq)
);
CREATE TABLE revision_blobs (
    account_id uuid NOT NULL,
    revision_id text NOT NULL,
    blob_id text NOT NULL,
    PRIMARY KEY(account_id, revision_id, blob_id),
    FOREIGN KEY(account_id, revision_id) REFERENCES revisions(account_id, id),
    FOREIGN KEY(account_id, blob_id) REFERENCES blobs(account_id, id)
);
