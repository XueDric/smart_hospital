export class LoginResult {
  token: string = '';
  expiresAt: number = 0;
  userId: number = 0;
  role: string = '';
  refId: number = 0;
  displayName: string = '';
}

export class VisitItem {
  appointmentId: number = 0;
  patientId: number = 0;
  doctorId: number = 0;
  departmentId: number = 0;
  visitDate: string = '';
  period: string = '';
  seqNo: number = 0;
  status: string = '';
  recordId: number = 0;
  recordStatus: string = 'none';
  recordFilled: number = 0;
  recordTotal: number = 7;
}

export class EmrSection {
  key: string = '';
  label: string = '';
  value: string = '';
  maxLen: number = 0;
  requiredToLock: boolean = false;
}

export class EmrRecord {
  id: number = 0;
  appointmentId: number = 0;
  patientId: number = 0;
  doctorId: number = 0;
  status: string = 'none';
  locked: boolean = false;
  filled: number = 0;
  totalSections: number = 7;
  complete: boolean = false;
  updatedBy: number = 0;
  createdAt: number = 0;
  updatedAt: number = 0;
  missingRequired: string[] = [];
  sections: EmrSection[] = [];
}
