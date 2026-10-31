/// Spacing and component sizes of the NEXUS chat design (px). One place, so a
/// widget never carries a bare number.
abstract final class NxSpace {
  static const double s2 = 2, s3 = 3, s4 = 4, s6 = 6, s8 = 8, s10 = 10;
  static const double s12 = 12, s14 = 14, s16 = 16, s20 = 20;
}

abstract final class NxSize {
  // Chrome and panes
  static const double titleBar = 44, header = 52, hairline = 1, focusRing = 3;
  static const double checkBorder = 1.5;
  static const double sidebar = 248, thread = 300;
  static const double ctrl = 28, ctrlSm = 24, toolbarBtn = 26, ctrlIcon = 16;
  static const double icon = 16, iconSm = 14, iconXs = 12;
  static const double spinner = 2, progress = 2, spinnerBox = 20;

  // Sidebar
  static const double search = 32, row = 30, chipPad = 10, chipPadV = 3;

  /// A hairline needs 5 px of clear air from any text box (the contrast
  /// guideline reads 4 px around the box); pills use this vertical padding.
  static const double pillPadV = 5, tapPadV = 3;
  static const double pill = 18, pillRadius = 9, pillPad = 5, pillMin = 18;
  static const double avatarSm = 20, avatarFace = 18, presenceDot = 8;
  static const double avatarSmRadius = 6, faceStep = .7, faceBorder = 2;
  static const double groupTop = 14, hereRadius = 8, hereButtonRadius = 7;
  static const double dashLength = 4, dashGap = 3, dashWidth = 1;

  // Messages
  static const double avatar = 32, avatarRadius = 8, reaction = 24;
  static const double fileIcon = 32, fileIconRadius = 6, imageHeight = 160;
  static const double previewHeight = 80, toolbarTop = 2;
  static const double codePadV = 8, codePadH = 10, mentionPadH = 3;

  // Composer
  static const int composerMaxLines = 5;
  static const double composerBottom = 14, composerReplyPad = 7;
  static const double send = 28, sendPad = 12;

  // Dialog frame
  static const double dialogInset = 16, dialogW = 1280, dialogH = 760;
  static const double dialogMinW = 280, dialogMinH = 350;
  static const double dialogMaxW = 1600, dialogMaxH = 1200;
  static const double resizeMinW = 600, resizeMinH = 400, handleSize = 12;
  static const double handlePad = 3;
  static const double personPickerW = 400, personPickerH = 380;
  static const double legacyW = 600, legacyH = 460, outboxW = 540;
  static const double outboxH = 350;

  // Responsive breakpoints (dialog width)
  static const double wide = 850, sideInline = 1150;
  static const double headerPill = 520, headerFaces = 640, composerHint = 420;
  static const double pagingExtent = 100;
  static const int faceLimit = 3, maxPeople = 8;
  static const int countCap = 99;
  static const int groupMinutes = 5;
}

abstract final class NxMotion {
  static const Duration fast = Duration(milliseconds: 120);
}
