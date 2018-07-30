#include "SMIbuffer/SMIbuffer.h"
#include <shared_mutex>
#include <vector>

namespace {
    typedef std::shared_timed_mutex mutex_type;
    typedef std::shared_lock<mutex_type> read_lock;
    typedef std::unique_lock<mutex_type> write_lock;
    mutex_type m;
    read_lock  lockForReading() { return  read_lock(m); }
    write_lock lockForWriting() { return write_lock(m); }

    std::vector<SMIbuffer*> SMIbufferClassInstances;  // for plain C callback to be able to call into the class instances

    template <typename T>
    inline std::vector<T> getData(mpmc_bounded_queue<T>* dataBuffer_, bool justDump_=false)
    {
        std::vector<T> data;
        if (!dataBuffer_)
            return data;

        while (true)
        {
            T temp;
            bool success = dataBuffer_->dequeue(temp);
            if (success && !justDump_)
                data.push_back(std::move(temp));
            else
                break;
        }
        return data;
    }
}

int __stdcall SMISampleCallback(SampleStruct sampleData_)
{
    auto l = lockForReading();
    for each (auto&& instance in SMIbufferClassInstances)
    {
        if (instance->_sampleData)
            instance->_sampleData->enqueue(sampleData_);
    }

    return 1;
}

int __stdcall SMIEventCallback(EventStruct eventData_)
{
    auto l = lockForReading();
    for each (auto&& instance in SMIbufferClassInstances)
    {
        if (instance->_eventData)
            instance->_eventData->enqueue(eventData_);
    }

    return 1;
}




SMIbuffer::SMIbuffer()
{
    auto l = lockForWriting();
    SMIbufferClassInstances.push_back(this);
}

SMIbuffer::~SMIbuffer()
{
    stopSampleBuffering(true);
    stopEventBuffering (true);

    auto l = lockForWriting();
    SMIbufferClassInstances.erase(std::remove(SMIbufferClassInstances.begin(), SMIbufferClassInstances.end(), this), SMIbufferClassInstances.end());
}

int SMIbuffer::startSampleBuffering(size_t bufferSize_ /*= 1<<22*/)
{
    if (!_sampleData)
        _sampleData = new mpmc_bounded_queue<SampleStruct>(bufferSize_);

    return iV_SetSampleCallback(SMISampleCallback);
}

int SMIbuffer::startEventBuffering(size_t bufferSize_ /*= 1<<20*/)
{
    if (!_eventData)
        _eventData = new mpmc_bounded_queue<EventStruct>(bufferSize_);

    return iV_SetEventCallback(SMIEventCallback);
}

void SMIbuffer::clearSampleBuffer()
{
    getData(_sampleData,true);
}

void SMIbuffer::clearEventBuffer()
{
    getData(_eventData,true);
}

void SMIbuffer::stopSampleBuffering(bool deleteBuffer_)
{
    iV_SetSampleCallback(nullptr);
    if (_sampleData && deleteBuffer_)
    {
        delete _sampleData;
        _sampleData = nullptr;
    }
}

void SMIbuffer::stopEventBuffering(bool deleteBuffer_)
{
    iV_SetEventCallback(nullptr);
    if (_eventData && deleteBuffer_)
    {
        delete _eventData;
        _eventData = nullptr;
    }
}

std::vector<SampleStruct> SMIbuffer::getSamples()
{
    return getData(_sampleData);
}

std::vector<EventStruct> SMIbuffer::getEvents()
{
    return getData(_eventData);
}
