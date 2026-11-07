import { Kysely, sql } from 'kysely';
import { randomUUID } from 'node:crypto';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { ConfigRepository } from 'src/repositories/config.repository.js';
import { DatabaseRepository } from 'src/repositories/database.repository.js';
import { EventRepository } from 'src/repositories/event.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { SystemMetadataRepository } from 'src/repositories/system-metadata.repository.js';
import { DB } from 'src/schema/index.js';
import { down, up } from 'src/schema/migrations/1794078000000-GalleryReview.js';
import { AssetService } from 'src/services/asset.service.js';
import { GalleryReviewService } from 'src/services/gallery-review.service.js';
import { getKyselyConfig } from 'src/utils/database.js';
import { newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { automock } from 'test/utils.js';

let db: Kysely<DB>;
let sut: GalleryReviewService;
let ctx: ReturnType<typeof newMediumService<typeof AssetService>>['ctx'];
const policy = {
  name: 'Synthetic phone',
  platform: 'android' as const,
  localEnabled: true,
  remoteEnabled: true,
  canManage: true,
};
beforeAll(async () => {
  const url = process.env.GALLERY_TEST_DATABASE_URL;
  if (!url || new URL(url).pathname !== '/gallery_review_test')
    throw new Error('Use a disposable gallery_review_test database');
  db = new Kysely<DB>(getKyselyConfig({ connectionType: 'url', url }));
  const config = new ConfigRepository();
  const logger = LoggingRepository.create();
  await new DatabaseRepository(db, logger, config).runMigrations();
  ctx = newMediumService(AssetService, { database: db, real: [], mock: [LoggingRepository] }).ctx;
  sut = new GalleryReviewService(
    db,
    automock(EventRepository, { args: [undefined, config, logger], strict: false }),
    new AccessRepository(db),
    config,
    ctx.get(SystemMetadataRepository),
    logger,
  );
});
afterAll(async () => {
  await db?.destroy();
});

async function scenario() {
  const { auth, user } = await ctx.newSyncAuthUser();
  const { session } = await ctx.newSession({ userId: user.id });
  const other = factory.auth({ user: auth.user, session });
  const first = await sut.register(auth, policy);
  const second = await sut.register(other, policy);
  const { asset } = await ctx.newAsset({ ownerId: user.id });
  return { auth, other, first, second, asset };
}
const decision = (assetId: string, devices: string[] = [], server = true) => ({
  operationId: randomUUID(),
  assetId,
  devices,
  server,
  action: 'trash' as const,
});
const state = async (id: string) => {
  const asset = await db.selectFrom('asset').select('status').where('id', '=', id).executeTakeFirst();
  return asset?.status;
};

it('keeps server-only trash off both phones and retains exclusion after purge', async () => {
  const { auth, other, asset } = await scenario();
  await sut.decide(auth, decision(asset.id));
  expect(await state(asset.id)).toBe('trashed');
  expect(await sut.commands(auth)).toEqual([]);
  expect(await sut.commands(other)).toEqual([]);
  await db.deleteFrom('asset').where('id', '=', asset.id).execute();
  expect(await sut.exclusions(auth, { checksums: [asset.checksum.toString('base64')] })).toEqual({
    blocked: [asset.checksum.toString('base64')],
  });
  expect(await sut.commands(other)).toEqual([]);
});
it('device-only trash leaves server active and Undo supersedes the queued revision', async () => {
  const { auth, other, first, asset } = await scenario();
  const dto = decision(asset.id, [first.deviceId], false);
  await sut.decide(auth, dto);
  expect(await state(asset.id)).toBe('active');
  expect(await sut.commands(other)).toEqual([]);
  const [trash] = await sut.commands(auth);
  await sut.undo(auth, dto.operationId);
  await sut.ack(auth, { revision: trash.revision, status: 'applied' });
  expect(await sut.commands(auth)).toMatchObject([{ action: 'restore' }]);
  await sut.undo(auth, dto.operationId);
});
it('retries one decision without duplicating or resetting acknowledged work', async () => {
  const { auth, first, asset } = await scenario();
  const dto = decision(asset.id, [first.deviceId]);
  await sut.decide(auth, dto);
  const [command] = await sut.commands(auth);
  await sut.ack(auth, { revision: command.revision, status: 'applied' });
  await sut.decide(auth, dto);
  expect(await sut.commands(auth)).toEqual([]);
  await expect(sut.decide(auth, { ...dto, devices: [] })).rejects.toThrow('different decision');
});
it('isolates devices, decisions and acknowledgements by account', async () => {
  const a = await scenario();
  const b = await scenario();
  const devices = await sut.devices(a.auth);
  expect(devices.some((d) => d.id === b.first.deviceId)).toBe(false);
  await expect(sut.decide(a.auth, decision(a.asset.id, [b.first.deviceId], false))).rejects.toThrow();
  await expect(sut.decide(a.auth, decision(b.asset.id))).rejects.toThrow();
  const dto = decision(a.asset.id, [a.first.deviceId], false);
  await sut.decide(a.auth, dto);
  const [command] = await sut.commands(a.auth);
  await sut.ack(b.auth, { revision: command.revision, status: 'applied' });
  expect(await sut.commands(a.auth)).toHaveLength(1);
  await expect(sut.operation(b.auth, dto.operationId)).rejects.toThrow();
  await sut.undo(b.auth, dto.operationId);
  const operation = await sut.operation(a.auth, dto.operationId);
  expect(operation.undone).toBe(false);
});
it('cancels pending commands on opt-out and does not replay on opt-in', async () => {
  const { auth, other, second, asset } = await scenario();
  await sut.decide(auth, decision(asset.id, [second.deviceId], false));
  await sut.register(other, { ...policy, remoteEnabled: false });
  expect(await sut.commands(other)).toEqual([]);
  const devices = await sut.devices(auth);
  expect(devices.find((d) => d.id === second.deviceId)?.enabled).toBe(false);
  await expect(sut.decide(auth, decision(asset.id, [second.deviceId], false))).rejects.toThrow();
  await sut.register(other, policy);
  expect(await sut.commands(other)).toEqual([]);
});
it('stock changes obey current-phone and remote opt-ins independently', async () => {
  const { auth, other, asset } = await scenario();
  await sut.register(auth, { ...policy, localEnabled: false });
  await db.transaction().execute(async (tx) => {
    await sql`SELECT set_config('gallery_review.source_session', ${auth.session!.id}, true)`.execute(tx);
    await tx
      .updateTable('asset')
      .set({ deletedAt: new Date(), status: 'trashed' as never })
      .where('id', '=', asset.id)
      .execute();
  });
  expect(await sut.commands(auth)).toEqual([]);
  expect(await sut.commands(other)).toMatchObject([{ action: 'trash', local: false }]);
});
it('Trash restore is server-only, clears exclusion and can be undone', async () => {
  const { auth, other, first, asset } = await scenario();
  await sut.decide(auth, decision(asset.id));
  const restore = { ...decision(asset.id), action: 'restore' as const };
  await expect(sut.decide(auth, { ...restore, devices: [first.deviceId] })).rejects.toThrow('only the server');
  await sut.decide(auth, restore);
  expect(await state(asset.id)).toBe('active');
  expect(await sut.exclusions(auth, { checksums: [asset.checksum.toString('base64')] })).toEqual({ blocked: [] });
  expect(await sut.commands(other)).toEqual([]);
  await sut.undo(auth, restore.operationId);
  expect(await state(asset.id)).toBe('trashed');
});
it('Undo refuses to overwrite a subsequent stock state change', async () => {
  const { auth, asset } = await scenario();
  const dto = decision(asset.id);
  await sut.decide(auth, dto);
  await db
    .updateTable('asset')
    .set({ deletedAt: null, status: 'active' as never })
    .where('id', '=', asset.id)
    .execute();
  await db
    .updateTable('asset')
    .set({ deletedAt: new Date(), status: 'trashed' as never })
    .where('id', '=', asset.id)
    .execute();
  await expect(sut.undo(auth, dto.operationId)).rejects.toThrow('changed');
});
it('blocks a registered uploader after purge but preserves stock upload behavior', async () => {
  const { auth, asset } = await scenario();
  await sut.decide(auth, decision(asset.id));
  await db.deleteFrom('asset').where('id', '=', asset.id).execute();
  const repository = ctx.get(AssetRepository);
  const copy = { ...asset, id: randomUUID() };
  await expect(repository.createForUpload(copy, auth.session!.id)).rejects.toThrow();
  await expect(repository.createForUpload(copy)).resolves.toBeDefined();
});
it('rejects API-key registration and disables unsupported platforms', async () => {
  const { auth } = await scenario();
  await expect(sut.register({ ...auth, session: undefined }, policy)).rejects.toThrow('session');
  await sut.register(auth, { ...policy, platform: 'ios' });
  const devices = await sut.devices(auth);
  expect(devices.find((d) => d.current)?.enabled).toBe(false);
});

it('account deletion cascades without recreating exclusions or devices', async () => {
  const { auth } = await scenario();
  await db.deleteFrom('user').where('id', '=', auth.user.id).execute();
  expect(await sut.devices(auth)).toEqual([]);
});
it('session revocation disables the old destination', async () => {
  const { auth, other, second } = await scenario();
  await db.deleteFrom('session').where('id', '=', other.session!.id).execute();
  const devices = await sut.devices(auth);
  expect(devices.find((d) => d.id === second.deviceId)).toMatchObject({
    enabled: false,
    reason: 'Signed out',
  });
});
it('metadata updates do not invalidate Undo', async () => {
  const { auth, asset } = await scenario();
  const dto = decision(asset.id);
  await sut.decide(auth, dto);
  await db.updateTable('asset').set({ originalFileName: 'renamed.jpg' }).where('id', '=', asset.id).execute();
  await sut.undo(auth, dto.operationId);
  expect(await state(asset.id)).toBe('active');
});

it('Undo cancels an uncertain request before it arrives and prevents a late retry', async () => {
  const { auth, asset } = await scenario();
  const dto = decision(asset.id);
  await sut.undo(auth, dto.operationId);
  await expect(sut.decide(auth, dto)).rejects.toThrow('already been undone');
  expect(await state(asset.id)).toBe('active');
});

it('server-only Live Photo purge keeps the motion copy excluded without queuing phone deletion', async () => {
  const { auth, other, asset } = await scenario();
  const { asset: motion } = await ctx.newAsset({ ownerId: auth.user.id });
  await db.updateTable('asset').set({ livePhotoVideoId: motion.id }).where('id', '=', asset.id).execute();
  await sut.decide(auth, decision(asset.id));
  await db.deleteFrom('asset').where('id', '=', asset.id).execute();
  await db.deleteFrom('asset').where('id', '=', motion.id).execute();
  expect(await sut.commands(other)).toEqual([]);
  expect(await sut.exclusions(auth, { checksums: [motion.checksum.toString('base64')] })).toEqual({
    blocked: [motion.checksum.toString('base64')],
  });
});

it('same-account sign-in can recover a pending server decision after the old session is revoked', async () => {
  const { auth, other, asset } = await scenario();
  const dto = decision(asset.id);
  await sut.decide(auth, dto);
  await db.deleteFrom('session').where('id', '=', auth.session!.id).execute();
  await sut.decide(other, dto);
  expect(await state(asset.id)).toBe('trashed');
  await sut.undo(other, dto.operationId);
  expect(await state(asset.id)).toBe('active');
});

it('extension rollback/reapply preserves upstream assets', async () => {
  const before = await db.selectFrom('asset').select('id').execute();
  await down(db);
  const absent = await sql`SELECT to_regnamespace('gallery_review') AS schema`.execute(db);
  expect(absent.rows).toEqual([{ schema: null }]);
  await up(db);
  const after = await db.selectFrom('asset').select('id').execute();
  expect(after.map((a) => a.id).sort()).toEqual(before.map((a) => a.id).sort());
});
