/*
 * Copyright (c) 2012-2013, Eelco Cramer
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
 *
 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <v8.h>
#include <node.h>
#include <nan.h>
#include <node_buffer.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include "BTSerialPortBinding.h"
#include "BluetoothWorker.h"

extern "C"{
    #include <stdio.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <stdlib.h>
    #include <signal.h>
    #include <termios.h>
    #include <sys/poll.h>
    #include <sys/ioctl.h>
    #include <sys/socket.h>
    #include <sys/types.h>
    #include <assert.h>
}

#import <Foundation/NSObject.h>

using namespace node;
using namespace v8;

uv_mutex_t write_queue_mutex;
ngx_queue_t write_queue;

void BTSerialPortBinding::EIO_Connect(uv_work_t *req) {
    connect_baton_t *baton = static_cast<connect_baton_t *>(req->data);

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *address = [NSString stringWithCString:baton->address encoding:NSASCIIStringEncoding];
    BluetoothWorker *worker = [BluetoothWorker getInstance: address];
    // create pipe to communicate with delegate
    pipe_t *pipe = pipe_new(sizeof(unsigned char), 0);

    IOReturn result = [worker connectDevice: address onChannel:baton->channelID withPipe:pipe];

    if (result == kIOReturnSuccess) {
        pipe_consumer_t *c = pipe_consumer_new(pipe);

        // save consumer side of the pipe
        baton->rfcomm->consumer = c;
        baton->status = 0;
    } else {
        baton->status = 1;
    }

    pipe_free(pipe);
    [pool release];
}

void BTSerialPortBinding::EIO_AfterConnect(uv_work_t *req) {
    connect_baton_t *baton = static_cast<connect_baton_t *>(req->data);

    TryCatch try_catch;

    if (baton->status == 0) {
        baton->cb->Call(0, NULL);
    } else {
        Handle<Value> argv[] = {
            NanError("Cannot connect")
        };
        baton->ecb->Call(1, argv);
    }

    if (try_catch.HasCaught()) {
        FatalException(try_catch);
    }

    baton->rfcomm->Unref();

    delete baton->cb;
    delete baton->ecb;
    delete baton;
    baton = NULL;
}

void BTSerialPortBinding::EIO_Write(uv_work_t *req) {
    queued_write_t *queuedWrite = static_cast<queued_write_t*>(req->data);
    write_baton_t *data = static_cast<write_baton_t*>(queuedWrite->baton);

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *address = [NSString stringWithCString:data->address encoding:NSASCIIStringEncoding];
    BluetoothWorker *worker = [BluetoothWorker getInstance: address];

    if ([worker writeAsync: data->bufferData length: data->bufferLength toDevice: address] != kIOReturnSuccess) {
        sprintf(data->errorString, "Write was unsuccessful");
    } else {
        data->result = data->bufferLength;
    }

    [pool release];
}

void BTSerialPortBinding::EIO_AfterWrite(uv_work_t *req) {
    queued_write_t *queuedWrite = static_cast<queued_write_t*>(req->data);
    write_baton_t *data = static_cast<write_baton_t*>(queuedWrite->baton);

    Handle<Value> argv[2];
    if (data->errorString[0]) {
        argv[0] = NanError(data->errorString);
        argv[1] = NanUndefined();
    } else {
        argv[0] = NanUndefined();
        argv[1] = NanNew<v8::Integer>((int32_t)data->result);
    }

    data->callback->Call(2, argv);

    uv_mutex_lock(&write_queue_mutex);
    ngx_queue_remove(&queuedWrite->queue);

    if (!ngx_queue_empty(&write_queue)) {
        // Always pull the next work item from the head of the queue
        ngx_queue_t* head = ngx_queue_head(&write_queue);
        queued_write_t* nextQueuedWrite = ngx_queue_data(head, queued_write_t, queue);
        uv_queue_work(uv_default_loop(), &nextQueuedWrite->req, EIO_Write, (uv_after_work_cb)EIO_AfterWrite);
    }
    uv_mutex_unlock(&write_queue_mutex);

    NanDisposePersistent(data->buffer);
    delete data->callback;
    data->rfcomm->Unref();

    delete data;
    delete queuedWrite;
}

void BTSerialPortBinding::EIO_Read(uv_work_t *req) {
    unsigned int buf[1024] = { 0 };

    read_baton_t *baton = static_cast<read_baton_t *>(req->data);
    size_t size = 0;

    memset(buf, 0, sizeof(buf));

    if (baton->rfcomm->consumer != NULL) {
        size = pipe_pop_eager(baton->rfcomm->consumer, buf, sizeof(buf));
    }

    if (size == 0) {
        pipe_consumer_free(baton->rfcomm->consumer);
        baton->rfcomm->consumer = NULL;
    }

    // when no data is read from rfcomm the connection has been closed.
    baton->size = size;
    memcpy(&baton->result, buf, size);
}

void BTSerialPortBinding::EIO_AfterRead(uv_work_t *req) {
    NanEscapableScope();

    read_baton_t *baton = static_cast<read_baton_t *>(req->data);

    TryCatch try_catch;

    Handle<Value> argv[2];

    if (baton->size < 0) {
        argv[0] = NanError("Error reading from connection");
        argv[1] = NanUndefined();
    } else {
        Local<Object> globalObj = NanGetCurrentContext()->Global();
        Local<Function> bufferConstructor = Local<Function>::Cast(globalObj->Get(NanNew("Buffer")));
        Handle<Value> constructorArgs[1] = { NanNew<v8::Integer>(baton->size) };
        Local<Object> resultBuffer = bufferConstructor->NewInstance(1, constructorArgs);
        memcpy(Buffer::Data(resultBuffer), baton->result, baton->size);

        argv[0] = NanUndefined();
        argv[1] = NanEscapeScope(resultBuffer);
    }

    baton->cb->Call(2, argv);

    if (try_catch.HasCaught()) {
        FatalException(try_catch);
    }

    baton->rfcomm->Unref();
    delete baton->cb;
    delete baton;
    baton = NULL;
}

void BTSerialPortBinding::Init(Handle<Object> target) {
    NanScope();

    Local<FunctionTemplate> t = NanNew<FunctionTemplate>(New);

    t->InstanceTemplate()->SetInternalFieldCount(1);
    t->SetClassName(NanNew("BTSerialPortBinding"));

    NODE_SET_PROTOTYPE_METHOD(t, "write", Write);
    NODE_SET_PROTOTYPE_METHOD(t, "read", Read);
    NODE_SET_PROTOTYPE_METHOD(t, "close", Close);
    target->Set(NanNew("BTSerialPortBinding"), t->GetFunction());
    target->Set(NanNew("BTSerialPortBinding"), t->GetFunction());
    target->Set(NanNew("BTSerialPortBinding"), t->GetFunction());
}

BTSerialPortBinding::BTSerialPortBinding() :
    consumer(NULL) {
}

BTSerialPortBinding::~BTSerialPortBinding() {
}

NAN_METHOD(BTSerialPortBinding::New) {
    NanScope();

    uv_mutex_init(&write_queue_mutex);
    ngx_queue_init(&write_queue);

    const char *usage = "usage: BTSerialPortBinding(address, channelID, callback, error)";
    if (args.Length() != 4) {
        NanThrowError(usage);
    }

    String::Utf8Value address(args[0]);

    int channelID = args[1]->Int32Value();
    if (channelID <= 0) {
        NanThrowTypeError("ChannelID should be a positive int value.");
    }

    BTSerialPortBinding* rfcomm = new BTSerialPortBinding();
    rfcomm->Wrap(args.This());

    connect_baton_t *baton = new connect_baton_t();
    baton->rfcomm = ObjectWrap::Unwrap<BTSerialPortBinding>(args.This());
    baton->channelID = channelID;

    strcpy(baton->address, *address);
    baton->cb = new NanCallback(args[2].As<Function>());
    baton->ecb = new NanCallback(args[3].As<Function>());
    baton->request.data = baton;
    baton->rfcomm->Ref();

    uv_queue_work(uv_default_loop(), &baton->request, EIO_Connect, (uv_after_work_cb)EIO_AfterConnect);

    NanReturnValue(args.This());
}

NAN_METHOD(BTSerialPortBinding::Write) {
    NanScope();

    // usage
    if (args.Length() != 3) {
        NanThrowError("usage: write(buf, address, callback)");
    }

    // buffer
    if(!args[0]->IsObject() || !Buffer::HasInstance(args[0])) {
        NanThrowTypeError("First argument must be a buffer");
    }
    Local<Object> bufferObject = args[0].As<Object>();
    void* bufferData = Buffer::Data(bufferObject);
    size_t bufferLength = Buffer::Length(bufferObject);

    // string
    if (!args[1]->IsString()) {
        NanThrowTypeError("Second argument must be a string");
    }
    String::Utf8Value addressParameter(args[1]);

    // callback
    if(!args[2]->IsFunction()) {
        NanThrowTypeError("Third argument must be a function");
    }

    write_baton_t *baton = new write_baton_t();
    memset(baton, 0, sizeof(write_baton_t));
    strcpy(baton->address, *addressParameter);
    baton->rfcomm = ObjectWrap::Unwrap<BTSerialPortBinding>(args.This());
    baton->rfcomm->Ref();
    NanAssignPersistent(baton->buffer, bufferObject);
    baton->bufferData = bufferData;
    baton->bufferLength = bufferLength;
    baton->callback = new NanCallback(args[2].As<Function>());

    queued_write_t *queuedWrite = new queued_write_t();
    memset(queuedWrite, 0, sizeof(queued_write_t));
    queuedWrite->baton = baton;
    queuedWrite->req.data = queuedWrite;

    uv_mutex_lock(&write_queue_mutex);
    bool empty = ngx_queue_empty(&write_queue);

    ngx_queue_insert_tail(&write_queue, &queuedWrite->queue);

    if (empty) {
        uv_queue_work(uv_default_loop(), &queuedWrite->req, EIO_Write, (uv_after_work_cb)EIO_AfterWrite);
    }
    uv_mutex_unlock(&write_queue_mutex);

    NanReturnUndefined();
}

NAN_METHOD(BTSerialPortBinding::Close) {
    NanScope();

    if (args.Length() != 1) {
        NanThrowError("usage: close(address)");
    }

    if (!args[0]->IsString()) {
        NanThrowTypeError("Argument should be a string value");
    }

    //TODO should be a better way to do this...
    String::Utf8Value addressParameter(args[0]);
    char addressArray[32];
    strncpy(addressArray, *addressParameter, 32);
    NSString *address = [NSString stringWithCString:addressArray encoding:NSASCIIStringEncoding];

    BluetoothWorker *worker = [BluetoothWorker getInstance: address];
    [worker disconnectFromDevice: address];

    NanReturnUndefined();
}

NAN_METHOD(BTSerialPortBinding::Read) {
    NanScope();

    if (args.Length() != 1) {
        NanThrowError("usage: read(callback)");
    }

    Local<Function> cb = args[0].As<Function>();

    BTSerialPortBinding* rfcomm = ObjectWrap::Unwrap<BTSerialPortBinding>(args.This());

    // callback with an error if the connection has been closed.
    if (rfcomm->consumer == NULL) {
        Handle<Value> argv[2];

        argv[0] = NanError("The connection has been closed");
        argv[1] = NanUndefined();

        NanCallback *nc = new NanCallback(cb);
        nc->Call(2, argv);
    } else {
        read_baton_t *baton = new read_baton_t();
        baton->rfcomm = rfcomm;
        baton->cb = new NanCallback(cb);
        baton->request.data = baton;
        baton->rfcomm->Ref();

        uv_queue_work(uv_default_loop(), &baton->request, EIO_Read, (uv_after_work_cb)EIO_AfterRead);
    }

    NanReturnUndefined();
}
