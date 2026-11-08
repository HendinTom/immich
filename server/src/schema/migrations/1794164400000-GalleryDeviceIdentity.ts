import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`ALTER TABLE gallery_review.device
    ADD COLUMN identity_key text,
    ADD COLUMN installation_id uuid,
    ADD COLUMN retired boolean NOT NULL DEFAULT false,
    ADD CONSTRAINT device_owner_identity UNIQUE(owner_id, identity_key)`.execute(db);
  await sql`CREATE TABLE gallery_review.device_session (
    session_id uuid PRIMARY KEY,
    device_id uuid NOT NULL REFERENCES gallery_review.device(id) ON DELETE CASCADE
  )`.execute(db);
  await sql`INSERT INTO gallery_review.device_session SELECT session_id,id FROM gallery_review.device
    WHERE session_id IS NOT NULL`.execute(db);
  await sql`ALTER TABLE gallery_review.delivery ADD COLUMN retired boolean NOT NULL DEFAULT false`.execute(db);
  await sql`DO $$ BEGIN EXECUTE replace(replace(
    pg_get_functiondef('gallery_review.asset_state()'::regprocedure),
    'AND can_manage', 'AND can_manage AND NOT retired'),
    'status = ''pending'', updated_at', 'status = ''pending'', retired = false, updated_at'); END $$`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DO $$ BEGIN EXECUTE replace(replace(
    pg_get_functiondef('gallery_review.asset_state()'::regprocedure),
    'AND can_manage AND NOT retired', 'AND can_manage'),
    'status = ''pending'', retired = false, updated_at', 'status = ''pending'', updated_at'); END $$`.execute(db);
  await sql`ALTER TABLE gallery_review.delivery DROP COLUMN retired`.execute(db);
  await sql`DROP TABLE gallery_review.device_session`.execute(db);
  await sql`ALTER TABLE gallery_review.device DROP COLUMN identity_key, DROP COLUMN installation_id,
    DROP COLUMN retired`.execute(db);
}
