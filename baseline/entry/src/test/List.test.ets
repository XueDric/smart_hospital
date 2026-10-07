import dateFmtTest from './DateFmt.test';
import clientTokenTest from './ClientToken.test';
import planTreeTest from './PlanTree.test';
import calendarSyncTest from './CalendarSync.test';

export default function testsuite() {
  dateFmtTest();
  clientTokenTest();
  planTreeTest();
  calendarSyncTest();
}
