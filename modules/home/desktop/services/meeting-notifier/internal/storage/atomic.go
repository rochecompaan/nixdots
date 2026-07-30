package storage

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type OperationStage string

const (
	StageRead           OperationStage = "read"
	StageReadClose      OperationStage = "read-close"
	StageTempCreate     OperationStage = "temp-create"
	StageTempChmod      OperationStage = "temp-chmod"
	StageTempWrite      OperationStage = "temp-write"
	StageTempSync       OperationStage = "temp-sync"
	StageTempClose      OperationStage = "temp-close"
	StageRename         OperationStage = "rename"
	StageDirectoryOpen  OperationStage = "directory-open"
	StageDirectorySync  OperationStage = "directory-sync"
	StageDirectoryClose OperationStage = "directory-close"
	StageLockOpen       OperationStage = "lock-open"
	StageLock           OperationStage = "lock"
	StageUnlock         OperationStage = "unlock"
)

type OperationError struct {
	Stage OperationStage
	Path  string
	Err   error
}

func (e *OperationError) Error() string {
	return fmt.Sprintf("storage %s %s: %v", e.Stage, e.Path, e.Err)
}

func (e *OperationError) Unwrap() error { return e.Err }

type fileHandle interface {
	io.Reader
	io.Writer
	Chmod(os.FileMode) error
	Close() error
	Name() string
	Stat() (os.FileInfo, error)
	Sync() error
}

type fileOperations struct {
	createTemp func(string, string) (fileHandle, error)
	open       func(string) (fileHandle, error)
	rename     func(string, string) error
}

func defaultFileOperations() fileOperations {
	return fileOperations{
		createTemp: func(dir, pattern string) (fileHandle, error) { return os.CreateTemp(dir, pattern) },
		open:       func(path string) (fileHandle, error) { return os.Open(path) },
		rename:     os.Rename,
	}
}

func atomicWrite(ops fileOperations, path string, data []byte) error {
	dir := filepath.Dir(path)
	temp, err := ops.createTemp(dir, "."+filepath.Base(path)+"-*")
	if err != nil {
		return operationError(StageTempCreate, path, err)
	}
	tempPath := temp.Name()
	closed := false
	defer func() {
		if !closed {
			_ = temp.Close()
		}
		_ = os.Remove(tempPath)
	}()
	if err := temp.Chmod(0o600); err != nil {
		return operationError(StageTempChmod, path, err)
	}
	if _, err := temp.Write(data); err != nil {
		return operationError(StageTempWrite, path, err)
	}
	if err := temp.Sync(); err != nil {
		return operationError(StageTempSync, path, err)
	}
	if err := temp.Close(); err != nil {
		closed = true
		return operationError(StageTempClose, path, err)
	}
	closed = true
	if err := ops.rename(tempPath, path); err != nil {
		return operationError(StageRename, path, err)
	}

	parent, err := ops.open(dir)
	if err != nil {
		return operationError(StageDirectoryOpen, path, err)
	}
	if err := parent.Sync(); err != nil {
		_ = parent.Close()
		return operationError(StageDirectorySync, path, err)
	}
	if err := parent.Close(); err != nil {
		return operationError(StageDirectoryClose, path, err)
	}
	return nil
}

func readFile(ops fileOperations, path string) ([]byte, error) {
	file, err := ops.open(path)
	if err != nil {
		return nil, operationError(StageRead, path, err)
	}
	data, readErr := io.ReadAll(file)
	closeErr := file.Close()
	if readErr != nil {
		return nil, operationError(StageRead, path, readErr)
	}
	if closeErr != nil {
		return nil, operationError(StageReadClose, path, closeErr)
	}
	return data, nil
}

func operationError(stage OperationStage, path string, err error) error {
	if err == nil {
		return nil
	}
	var operation *OperationError
	if errors.As(err, &operation) {
		return err
	}
	return &OperationError{Stage: stage, Path: path, Err: err}
}
