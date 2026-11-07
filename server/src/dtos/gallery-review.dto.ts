import { createZodDto } from 'nestjs-zod';
import z from 'zod';

export class GalleryDeviceDto extends createZodDto(
  z
    .object({
      name: z.string().trim().min(1).max(100),
      platform: z.enum(['android', 'ios', 'other']),
      localEnabled: z.boolean(),
      remoteEnabled: z.boolean(),
      canManage: z.boolean(),
    })
    .strict(),
) {}

export class GalleryDecisionDto extends createZodDto(
  z
    .object({
      operationId: z.uuid(),
      assetId: z.uuid(),
      action: z.enum(['trash', 'restore']),
      server: z.boolean(),
      devices: z.array(z.uuid()).max(100),
    })
    .strict(),
) {}

export class GalleryAckDto extends createZodDto(
  z
    .object({
      revision: z.uuid(),
      status: z.enum(['applied', 'missing', 'blocked']),
    })
    .strict(),
) {}

export class GalleryChecksumsDto extends createZodDto(
  z
    .object({
      checksums: z.array(z.string().regex(/^[A-Za-z0-9+/]{27}=$/)).max(1000),
    })
    .strict(),
) {}
