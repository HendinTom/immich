import { BadRequestException, ConflictException, ForbiddenException, Injectable } from '@nestjs/common';
import { Kysely, Transaction, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { AuthDto } from 'src/dtos/auth.dto.js';
import {
  GalleryAckDto,
  GalleryChecksumsDto,
  GalleryDecisionDto,
  GalleryDeviceDto,
} from 'src/dtos/gallery-review.dto.js';
import { Permission } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { ConfigRepository } from 'src/repositories/config.repository.js';
import { EventRepository } from 'src/repositories/event.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { SystemMetadataRepository } from 'src/repositories/system-metadata.repository.js';
import { DB } from 'src/schema/index.js';
import { requireAccess } from 'src/utils/access.js';
import { getConfig } from 'src/utils/config.js';

type Device = {
  id: string;
  identity_key: string | null;
  installation_id: string | null;
  retired: boolean;
  name: string;
  platform: string;
  session_id: string | null;
  local_enabled: boolean;
  remote_enabled: boolean;
  can_manage: boolean;
  last_seen: Date;
};
type Operation = {
  id: string;
  session_id: string;
  asset_id: string;
  checksum: Buffer;
  action: string;
  server_selected: boolean;
  targets: string[];
  previous_status: string;
  previous_deleted_at: Date | null;
  created_at: Date;
  undone: boolean;
  state_revision: string | null;
};
type Connection = Kysely<DB> | Transaction<DB>;

@Injectable()
export class GalleryReviewService {
  constructor(
    @InjectKysely() private db: Kysely<DB>,
    private events: EventRepository,
    private access: AccessRepository,
    private configRepo: ConfigRepository,
    private metadataRepo: SystemMetadataRepository,
    private logger: LoggingRepository,
  ) {}

  private session(auth: AuthDto) {
    if (!auth.session || auth.apiKey || auth.sharedLink) {
      throw new ForbiddenException('Gallery Review requires an authenticated user session');
    }
    return auth.session.id;
  }

  private async ownDevice(auth: AuthDto, db: Connection = this.db) {
    const session = this.session(auth);
    const { rows } = await sql<Device>`SELECT * FROM gallery_review.device
      WHERE owner_id=${auth.user.id} AND session_id=${session} AND NOT retired`.execute(db);
    if (!rows[0]) throw new ConflictException('Register this device before reviewing');
    return rows[0];
  }

  async register(auth: AuthDto, dto: GalleryDeviceDto) {
    const session = this.session(auth);
    if (!!dto.identityKey !== !!dto.installationId || (dto.replaceDeviceId && !dto.identityKey)) {
      throw new BadRequestException('Device and installation identity must be supplied together');
    }
    const canManage = dto.platform === 'android' && dto.canManage;
    return this.db.transaction().execute(async (db) => {
      // Serialize identity adoption, decisions and Undo for this account.
      await sql`SELECT pg_advisory_xact_lock(hashtextextended(${auth.user.id},0))`.execute(db);
      const { rows: bindings } = await sql<Device>`SELECT d.* FROM gallery_review.device d
        JOIN gallery_review.device_session s ON s.device_id=d.id
        WHERE s.session_id=${session} AND d.owner_id=${auth.user.id}`.execute(db);
      const bound = bindings[0];
      if (bound && (bound.retired || bound.session_id !== session)) {
        throw new ConflictException('This device session was replaced. Sign in again.');
      }
      if (
        bound?.identity_key &&
        (bound.identity_key !== dto.identityKey || bound.installation_id !== dto.installationId)
      ) {
        throw new ConflictException('Device identity changed. Sign in again.');
      }
      const { rows: matches } = dto.identityKey
        ? await sql<Device>`SELECT * FROM gallery_review.device WHERE owner_id=${auth.user.id}
            AND identity_key=${dto.identityKey} FOR UPDATE`.execute(db)
        : { rows: [] as Device[] };
      let device = matches[0] ?? bound;
      if (device?.retired || (bound && device && bound.id !== device.id)) {
        throw new ConflictException('Device identity is already associated with another entry');
      }
      const reinstalled = !!device?.installation_id && device.installation_id !== dto.installationId;
      if (device) {
        if (reinstalled) {
          // Retain historical receipts, but neither delivery nor Undo may replay
          // work belonging to the lost installation's native receipt journal.
          await sql`UPDATE gallery_review.delivery SET retired=true,
            status=CASE WHEN status='pending' THEN 'blocked' ELSE status END, updated_at=now()
            WHERE device_id=${device.id}`.execute(db);
        } else if (device.session_id !== session) {
          // A new login in the same installation retains self-request semantics.
          await sql`UPDATE gallery_review.delivery SET source_session=${session}
            WHERE device_id=${device.id} AND source_session IN
            (SELECT session_id FROM gallery_review.device_session WHERE device_id=${device.id})`.execute(db);
        }
        await sql`UPDATE gallery_review.device SET session_id=${session},
          identity_key=COALESCE(identity_key,${dto.identityKey ?? null}),
          installation_id=COALESCE(${dto.installationId ?? null},installation_id),
          name=${dto.name},platform=${dto.platform},local_enabled=${dto.localEnabled},
          remote_enabled=${dto.remoteEnabled},can_manage=${canManage},last_seen=now()
          WHERE id=${device.id}`.execute(db);
      } else {
        const { rows } = await sql<Device>`INSERT INTO gallery_review.device
          (owner_id,session_id,identity_key,installation_id,name,platform,local_enabled,remote_enabled,can_manage)
          VALUES(${auth.user.id},${session},${dto.identityKey ?? null},${dto.installationId ?? null},
            ${dto.name},${dto.platform},${dto.localEnabled},${dto.remoteEnabled},${canManage}) RETURNING *`.execute(db);
        device = rows[0];
      }
      await sql`INSERT INTO gallery_review.device_session(session_id,device_id)
        VALUES(${session},${device.id}) ON CONFLICT DO NOTHING`.execute(db);
      if (dto.replaceDeviceId) {
        const { rows } = await sql<Device>`SELECT * FROM gallery_review.device
          WHERE id=${dto.replaceDeviceId} AND owner_id=${auth.user.id} AND identity_key IS NULL
          AND NOT retired AND id<>${device.id} FOR UPDATE`.execute(db);
        if (!rows[0]) throw new ConflictException('Previous device entry is unavailable');
        await sql`UPDATE gallery_review.device SET retired=true,can_manage=false,
          local_enabled=false,remote_enabled=false WHERE id=${dto.replaceDeviceId}`.execute(db);
        await sql`UPDATE gallery_review.delivery SET retired=true,
          status=CASE WHEN status='pending' THEN 'blocked' ELSE status END,updated_at=now()
          WHERE device_id=${dto.replaceDeviceId}`.execute(db);
      }
      await sql`UPDATE gallery_review.delivery SET status='blocked', updated_at=now()
        WHERE device_id=${device.id} AND status='pending' AND NOT retired
        AND ((source_session=${session} AND NOT ${dto.localEnabled})
          OR (source_session IS DISTINCT FROM ${session} AND NOT ${dto.remoteEnabled}))`.execute(db);
      return { protocol: 1, deviceId: device.id, reinstalled };
    });
  }

  async devices(auth: AuthDto) {
    const session = this.session(auth);
    const { rows } =
      await sql<Device>`SELECT * FROM gallery_review.device WHERE owner_id=${auth.user.id} AND NOT retired
      ORDER BY (session_id=${session}) DESC NULLS LAST, name, id`.execute(this.db);
    return rows.map((d) => ({
      id: d.id,
      legacy: !d.identity_key,
      name: d.name,
      platform: d.platform,
      current: d.session_id === session,
      online: Date.now() - new Date(d.last_seen).getTime() < 120_000,
      enabled: !!d.session_id && d.can_manage && (d.session_id === session ? d.local_enabled : d.remote_enabled),
      reason: d.session_id
        ? d.can_manage
          ? (d.session_id === session ? d.local_enabled : d.remote_enabled)
            ? null
            : 'Deletions disabled on this device'
          : 'Device cannot manage local photos'
        : 'Signed out',
    }));
  }

  async commands(auth: AuthDto) {
    const device = await this.ownDevice(auth);
    if (!device.can_manage) return [];
    const { rows } = await sql<{ revision: string; checksum: string; action: string; local: boolean }>`
      SELECT revision, encode(checksum,'base64') AS checksum, action,
        source_session=${this.session(auth)} AS local
      FROM gallery_review.delivery WHERE device_id=${device.id} AND status='pending' AND NOT retired
        AND ((source_session=${this.session(auth)} AND ${device.local_enabled})
          OR (source_session IS DISTINCT FROM ${this.session(auth)} AND ${device.remote_enabled}))
      ORDER BY updated_at LIMIT 250`.execute(this.db);
    return rows;
  }

  async ack(auth: AuthDto, dto: GalleryAckDto) {
    const device = await this.ownDevice(auth);
    // An old acknowledgement cannot acknowledge a newer, superseding command.
    await sql`UPDATE gallery_review.delivery SET status=${dto.status}, updated_at=now()
      WHERE device_id=${device.id} AND revision=${dto.revision} AND status='pending' AND NOT retired`.execute(this.db);
    return { acknowledged: true };
  }

  async exclusions(auth: AuthDto, dto: GalleryChecksumsDto) {
    this.session(auth);
    if (dto.checksums.length === 0) return { blocked: [] };
    const { rows } = await sql<{ checksum: string }>`SELECT encode(checksum,'base64') AS checksum
      FROM gallery_review.exclusion WHERE owner_id=${auth.user.id} AND blocked
      AND checksum IN (${sql.join(dto.checksums.map((c) => Buffer.from(c, 'base64')))})`.execute(this.db);
    return { blocked: rows.map((r) => r.checksum) };
  }

  async decide(auth: AuthDto, dto: GalleryDecisionDto) {
    this.session(auth);
    const targets = [...new Set(dto.devices)].sort();
    if (!dto.server && targets.length === 0) throw new BadRequestException('Choose at least one destination');
    if (dto.action === 'restore' && (!dto.server || targets.length > 0)) {
      throw new BadRequestException('Trash review currently restores only the server copy');
    }
    await this.db.transaction().execute(async (db) => {
      await sql`SELECT pg_advisory_xact_lock(hashtextextended(${auth.user.id}, 0))`.execute(db);
      const device = await this.ownDevice(auth, db);
      const cancellation = await sql`SELECT id FROM gallery_review.cancellation
        WHERE owner_id=${auth.user.id} AND id=${dto.operationId}`.execute(db);
      if (cancellation.rows.length > 0) throw new ConflictException('Operation has already been undone');
      const {
        rows: [prior],
      } = await sql<Operation>`SELECT * FROM gallery_review.operation
        WHERE owner_id=${auth.user.id} AND id=${dto.operationId}`.execute(db);
      if (prior) {
        if (
          prior.asset_id !== dto.assetId ||
          prior.action !== dto.action ||
          prior.server_selected !== dto.server ||
          JSON.stringify(prior.targets) !== JSON.stringify(targets)
        ) {
          throw new ConflictException('Operation ID was already used for a different decision');
        }
        if (prior.undone) throw new ConflictException('Operation has already been undone');
        return;
      }
      await requireAccess(this.access, { auth, permission: Permission.AssetDelete, ids: [dto.assetId] });
      if (dto.server && dto.action === 'trash') {
        const config = await getConfig(
          { configRepo: this.configRepo, metadataRepo: this.metadataRepo, logger: this.logger },
          { withCache: true },
        );
        if (!config.trash.enabled) throw new ConflictException('Server Trash is disabled');
      }

      const {
        rows: [asset],
      } = await sql<{ checksum: Buffer; status: string; deletedAt: Date | null; livePhotoVideoId: string | null }>`
        SELECT checksum,status::text,"deletedAt","livePhotoVideoId" FROM public.asset
        WHERE id=${dto.assetId} AND "ownerId"=${auth.user.id} FOR UPDATE`.execute(db);
      if (!asset) throw new ForbiddenException('Asset is not owned by this account');
      if (dto.action === 'trash' ? asset.deletedAt !== null : asset.status !== 'trashed') {
        throw new ConflictException('Asset state changed; refresh the review');
      }
      if (targets.length > 0) {
        const { rows: selected } = await sql<Device>`SELECT * FROM gallery_review.device
          WHERE owner_id=${auth.user.id} AND id IN (${sql.join(targets)}) FOR UPDATE`.execute(db);
        if (
          selected.length !== targets.length ||
          selected.some(
            (d) =>
              d.retired || !d.session_id || !d.can_manage || !(d.id === device.id ? d.local_enabled : d.remote_enabled),
          )
        ) {
          throw new ConflictException('A selected device no longer allows deletion');
        }
      }
      await sql`INSERT INTO gallery_review.operation(id,owner_id,session_id,asset_id,checksum,action,
        server_selected,targets,previous_status,previous_deleted_at)
        VALUES(${dto.operationId},${auth.user.id},${this.session(auth)},${dto.assetId},${asset.checksum},${dto.action},
        ${dto.server},${sql`ARRAY[${sql.join(targets)}]::uuid[]`},${asset.status},${asset.deletedAt})`.execute(db);
      if (dto.server) {
        await sql`SELECT set_config('gallery_review.selective','true',true)`.execute(db);
        await sql`UPDATE public.asset SET status=${dto.action === 'trash' ? 'trashed' : 'active'}::assets_status_enum,
          "deletedAt"=${dto.action === 'trash' ? new Date() : null}
          WHERE id=${dto.assetId} AND "ownerId"=${auth.user.id}`.execute(db);
      }
      await sql`UPDATE gallery_review.operation SET state_revision=(SELECT revision FROM gallery_review.exclusion WHERE owner_id=${auth.user.id} AND checksum=${asset.checksum})
        WHERE owner_id=${auth.user.id} AND id=${dto.operationId}`.execute(db);
      for (const id of targets) {
        await sql`INSERT INTO gallery_review.delivery(device_id,checksum,operation_id,source_session,action)
          VALUES(${id},${asset.checksum},${dto.operationId},${this.session(auth)},'trash')
          ON CONFLICT(device_id,checksum) DO UPDATE SET revision=gen_random_uuid(),operation_id=EXCLUDED.operation_id,
            source_session=EXCLUDED.source_session,action='trash',status='pending',retired=false,updated_at=now()`.execute(
          db,
        );
      }
    });
    if (dto.server)
      await this.events.emit(dto.action === 'trash' ? 'AssetTrashAll' : 'AssetRestoreAll', {
        assetIds: [dto.assetId],
        userId: auth.user.id,
      });
    return this.operation(auth, dto.operationId);
  }

  async operation(auth: AuthDto, id: string) {
    this.session(auth);
    const {
      rows: [operation],
    } = await sql<Operation>`SELECT * FROM gallery_review.operation
      WHERE owner_id=${auth.user.id} AND id=${id}`.execute(this.db);
    if (!operation) {
      const cancellation = await sql`SELECT id FROM gallery_review.cancellation
        WHERE owner_id=${auth.user.id} AND id=${id}`.execute(this.db);
      if (cancellation.rows.length > 0) return { id, undone: true, devices: [] };
      throw new ForbiddenException('Operation not found');
    }
    const { rows } = await sql<{
      deviceId: string;
      status: string;
    }>`SELECT target AS "deviceId",CASE WHEN d.retired AND d.status='blocked' THEN 'cancelled' ELSE COALESCE(d.status,'superseded') END AS status
      FROM gallery_review.operation o CROSS JOIN LATERAL unnest(o.targets) AS target
      LEFT JOIN gallery_review.delivery d ON d.device_id=target AND d.operation_id=o.id
      WHERE o.owner_id=${auth.user.id} AND o.id=${id}`.execute(this.db);
    return { id, undone: operation.undone, devices: rows };
  }

  async undo(auth: AuthDto, id: string) {
    this.session(auth);
    let event: 'AssetTrashAll' | 'AssetRestoreAll' = 'AssetRestoreAll';
    const assetId = await this.db.transaction().execute(async (db) => {
      await sql`SELECT pg_advisory_xact_lock(hashtextextended(${auth.user.id},0))`.execute(db);
      const {
        rows: [op],
      } = await sql<Operation>`SELECT * FROM gallery_review.operation WHERE owner_id=${auth.user.id}
        AND id=${id} FOR UPDATE`.execute(db);
      if (!op) {
        // An uncertain client request may never have reached this server. Record
        // its cancellation under the same account lock so a late retry cannot act.
        await sql`INSERT INTO gallery_review.cancellation(owner_id,id,session_id)
          VALUES(${auth.user.id},${id},${this.session(auth)}) ON CONFLICT DO NOTHING`.execute(db);
        return null;
      }
      if (op.undone) return null;
      await requireAccess(this.access, { auth, permission: Permission.AssetDelete, ids: [op.asset_id] });
      const { rows: newer } = await sql`SELECT id FROM gallery_review.operation WHERE owner_id=${auth.user.id}
        AND checksum=${op.checksum} AND created_at>(SELECT created_at FROM gallery_review.operation WHERE owner_id=${auth.user.id} AND id=${id}) LIMIT 1`.execute(
        db,
      );
      if (newer.length > 0) throw new ConflictException('A newer review decision supersedes this operation');
      if (op.server_selected) {
        event = op.action === 'restore' ? 'AssetTrashAll' : 'AssetRestoreAll';
        const {
          rows: [asset],
        } = await sql<{ status: string; stateRevision: string | null }>`SELECT status::text,
          (SELECT revision FROM gallery_review.exclusion WHERE owner_id=${auth.user.id} AND checksum=${op.checksum}) AS "stateRevision" FROM public.asset
          WHERE id=${op.asset_id} AND "ownerId"=${auth.user.id} FOR UPDATE`.execute(db);
        if (
          !asset ||
          asset.stateRevision !== op.state_revision ||
          asset.status !== (op.action === 'trash' ? 'trashed' : 'active')
        ) {
          throw new ConflictException('The server copy changed or was permanently deleted');
        }
        await sql`SELECT set_config('gallery_review.selective','true',true)`.execute(db);
        await sql`UPDATE public.asset SET status=${op.previous_status}::assets_status_enum,
          "deletedAt"=${op.previous_deleted_at} WHERE id=${op.asset_id}`.execute(db);
      }
      // Superseding commands (including stock actions) are never overwritten.
      await sql`UPDATE gallery_review.delivery SET revision=gen_random_uuid(),action='restore',status='pending',updated_at=now()
        WHERE operation_id=${op.id} AND NOT retired AND device_id IN
        (SELECT id FROM gallery_review.device WHERE owner_id=${auth.user.id})`.execute(db);
      await sql`UPDATE gallery_review.operation SET undone=true WHERE owner_id=${auth.user.id} AND id=${id}`.execute(
        db,
      );
      return op.server_selected ? op.asset_id : null;
    });
    if (assetId) await this.events.emit(event, { assetIds: [assetId], userId: auth.user.id });
    return this.operation(auth, id);
  }
}
