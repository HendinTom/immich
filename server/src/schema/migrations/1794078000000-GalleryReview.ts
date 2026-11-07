import { Kysely, sql } from 'kysely';

// Keep the extension's tables in their own schema, separate from upstream's
// generated public-schema model. All ownership comes from authenticated users.
export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE SCHEMA gallery_review`.execute(db);
  await sql`CREATE TABLE gallery_review.device (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL REFERENCES public."user"(id) ON DELETE CASCADE,
    session_id uuid UNIQUE REFERENCES public.session(id) ON DELETE SET NULL,
    name text NOT NULL, platform text NOT NULL,
    local_enabled boolean NOT NULL DEFAULT true,
    remote_enabled boolean NOT NULL DEFAULT false,
    can_manage boolean NOT NULL DEFAULT false,
    last_seen timestamptz NOT NULL DEFAULT now()
  )`.execute(db);
  await sql`CREATE INDEX ON gallery_review.device(owner_id)`.execute(db);
  await sql`CREATE TABLE gallery_review.exclusion (
    owner_id uuid NOT NULL REFERENCES public."user"(id) ON DELETE CASCADE,
    checksum bytea NOT NULL,
    blocked boolean NOT NULL DEFAULT true,
    revision uuid NOT NULL DEFAULT gen_random_uuid(),
    PRIMARY KEY(owner_id, checksum)
  )`.execute(db);
  await sql`CREATE TABLE gallery_review.cancellation (
    owner_id uuid NOT NULL REFERENCES public."user"(id) ON DELETE CASCADE,
    id uuid NOT NULL, session_id uuid NOT NULL,
    PRIMARY KEY(owner_id,id)
  )`.execute(db);
  await sql`CREATE TABLE gallery_review.operation (
    id uuid NOT NULL,
    owner_id uuid NOT NULL REFERENCES public."user"(id) ON DELETE CASCADE,
    session_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    checksum bytea NOT NULL,
    action text NOT NULL CHECK(action IN ('trash','restore')),
    server_selected boolean NOT NULL,
    targets uuid[] NOT NULL,
    previous_status text NOT NULL,
    state_revision uuid,
    previous_deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    undone boolean NOT NULL DEFAULT false,
    PRIMARY KEY(owner_id, id)
  )`.execute(db);
  await sql`CREATE INDEX ON gallery_review.operation(owner_id, checksum, created_at)`.execute(db);
  await sql`CREATE TABLE gallery_review.delivery (
    device_id uuid NOT NULL REFERENCES gallery_review.device(id) ON DELETE CASCADE,
    checksum bytea NOT NULL,
    revision uuid NOT NULL DEFAULT gen_random_uuid(),
    operation_id uuid,
    source_session uuid,
    action text NOT NULL CHECK(action IN ('trash','restore')),
    status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','applied','missing','blocked')),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(device_id, checksum)
  )`.execute(db);
  // A stock client keeps its stock API behavior. Modified clients consume this
  // queue instead of interpreting every server Trash event as a local deletion.
  // Exclusions deliberately have no FK to asset: purging must not erase them.
  await sql`CREATE FUNCTION gallery_review.asset_state() RETURNS trigger LANGUAGE plpgsql AS $$
  DECLARE uid uuid; hash bytea; hashes bytea[]; command text; source uuid; was_blocked boolean;
  BEGIN
    IF TG_OP = 'DELETE' THEN
      uid := OLD."ownerId"; hash := OLD.checksum; command := 'trash';
    ELSE
      uid := NEW."ownerId"; hash := NEW.checksum;
      IF NEW."deletedAt" IS NOT DISTINCT FROM OLD."deletedAt" THEN RETURN NEW; END IF;
      IF NEW."deletedAt" IS NOT NULL AND OLD."deletedAt" IS NOT NULL THEN RETURN NEW; END IF;
      command := CASE WHEN NEW."deletedAt" IS NULL THEN 'restore' ELSE 'trash' END;
    END IF;
    -- User deletion cascades must not recreate rows for the deleted account.
    IF NOT EXISTS (SELECT 1 FROM public."user" WHERE id=uid) THEN RETURN NULL; END IF;
    SELECT blocked INTO was_blocked FROM gallery_review.exclusion WHERE owner_id=uid AND checksum=hash;
    hashes := ARRAY[hash];
    -- A Live Photo's motion file must follow the same upload exclusion and
    -- destination policy as its still, including a later background purge.
    IF TG_OP = 'UPDATE' AND NEW."livePhotoVideoId" IS NOT NULL THEN
      hashes := hashes || ARRAY(SELECT checksum FROM public.asset WHERE id=NEW."livePhotoVideoId" AND "ownerId"=uid);
    END IF;
    INSERT INTO gallery_review.exclusion(owner_id,checksum,blocked)
      SELECT uid, item, command='trash' FROM unnest(hashes) AS item
      ON CONFLICT(owner_id,checksum) DO UPDATE SET blocked=EXCLUDED.blocked,revision=gen_random_uuid();
    IF current_setting('gallery_review.selective', true) = 'true' THEN RETURN NULL; END IF;
    -- Final purge must not broaden a prior selective trash decision.
    IF TG_OP = 'DELETE' AND (OLD."deletedAt" IS NOT NULL OR was_blocked) THEN RETURN OLD; END IF;
    source := NULLIF(current_setting('gallery_review.source_session', true), '')::uuid;
    INSERT INTO gallery_review.delivery(device_id, checksum, action, source_session)
      SELECT id, item, command, source FROM gallery_review.device CROSS JOIN unnest(hashes) AS item
      WHERE owner_id = uid AND session_id IS NOT NULL AND can_manage
        AND CASE WHEN session_id = source THEN local_enabled ELSE remote_enabled END
      ON CONFLICT(device_id, checksum) DO UPDATE SET
        revision = gen_random_uuid(), operation_id = NULL, source_session = EXCLUDED.source_session,
        action = EXCLUDED.action, status = 'pending', updated_at = now();
    RETURN NULL;
  END $$`.execute(db);
  await sql`CREATE TRIGGER gallery_review_asset_state AFTER UPDATE OF "deletedAt" OR DELETE
    ON public.asset FOR EACH ROW EXECUTE FUNCTION gallery_review.asset_state()`.execute(db);
  // Existing server trash also must not be resurrected by newly registered phones.
  await sql`INSERT INTO gallery_review.exclusion(owner_id,checksum) SELECT "ownerId", checksum FROM public.asset
    WHERE "deletedAt" IS NOT NULL ON CONFLICT DO NOTHING`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP TRIGGER gallery_review_asset_state ON public.asset`.execute(db);
  await sql`DROP SCHEMA gallery_review CASCADE`.execute(db);
}
