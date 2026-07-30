package storage

import "math"

func (s *State) NormalizeLegacy() (bool, error) {
	changed := false
	if s.AuthWarningRevisions == nil {
		s.AuthWarningRevisions = make(map[string]uint64)
		changed = true
	}
	if s.PendingAuthWarnings == nil {
		s.PendingAuthWarnings = make(map[string]AuthWarningState)
		changed = true
	}
	for key, occurrence := range s.Occurrences {
		if occurrence.NotifyRevision == 0 && occurrence.Phase != PhaseScheduled && occurrence.Phase != PhaseJoined {
			occurrence.NotifyRevision = 1
			s.Occurrences[key] = occurrence
			changed = true
		}
		if occurrence.JoinRevision == 0 && (occurrence.Phase == PhaseJoinPending || occurrence.Phase == PhaseJoined) {
			occurrence.JoinRevision = 1
			s.Occurrences[key] = occurrence
			changed = true
		}
	}
	return changed, s.Validate()
}

func NextRevision(current uint64) (uint64, error) {
	if current == math.MaxUint64 {
		return 0, &ValidationError{Field: "notifyRevision", Value: "exhausted"}
	}
	return current + 1, nil
}
