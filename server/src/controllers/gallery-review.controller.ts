import { Body, Controller, Get, Param, ParseUUIDPipe, Post } from '@nestjs/common';
import { ApiExcludeController } from '@nestjs/swagger';
import type { AuthDto } from 'src/dtos/auth.dto.js';
import {
  GalleryAckDto,
  GalleryChecksumsDto,
  GalleryDecisionDto,
  GalleryDeviceDto,
} from 'src/dtos/gallery-review.dto.js';
import { Auth, Authenticated } from 'src/middleware/auth.guard.js';
import { GalleryReviewService } from 'src/services/gallery-review.service.js';

// Fork protocol v1 is documented separately; do not change upstream generated SDKs.
@ApiExcludeController()
@Controller('gallery-review')
export class GalleryReviewController {
  constructor(private service: GalleryReviewService) {}

  @Get('capabilities')
  @Authenticated()
  capabilities() {
    return { protocol: 1, deviceIdentity: 1, trashSources: ['server'] };
  }

  @Post('device')
  @Authenticated()
  register(@Auth() auth: AuthDto, @Body() dto: GalleryDeviceDto) {
    return this.service.register(auth, dto);
  }

  @Get('devices')
  @Authenticated()
  devices(@Auth() auth: AuthDto) {
    return this.service.devices(auth);
  }

  @Get('commands')
  @Authenticated()
  commands(@Auth() auth: AuthDto) {
    return this.service.commands(auth);
  }

  @Post('commands/ack')
  @Authenticated()
  ack(@Auth() auth: AuthDto, @Body() dto: GalleryAckDto) {
    return this.service.ack(auth, dto);
  }

  @Post('exclusions')
  @Authenticated()
  exclusions(@Auth() auth: AuthDto, @Body() dto: GalleryChecksumsDto) {
    return this.service.exclusions(auth, dto);
  }

  @Post('decisions')
  @Authenticated()
  decide(@Auth() auth: AuthDto, @Body() dto: GalleryDecisionDto) {
    return this.service.decide(auth, dto);
  }

  @Get('decisions/:id')
  @Authenticated()
  operation(@Auth() auth: AuthDto, @Param('id', ParseUUIDPipe) id: string) {
    return this.service.operation(auth, id);
  }

  @Post('decisions/:id/undo')
  @Authenticated()
  undo(@Auth() auth: AuthDto, @Param('id', ParseUUIDPipe) id: string) {
    return this.service.undo(auth, id);
  }
}
