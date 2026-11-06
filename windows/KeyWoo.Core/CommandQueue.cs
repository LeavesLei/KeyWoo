namespace KeyWoo.Core;

/// Fixed-capacity multiple-producer/single-consumer ring. Only producers contend
/// on a CAS; the audio consumer never locks, waits, or allocates. Sequence numbers
/// publish each slot after its complete value has been written.
public sealed class CommandQueue<T> where T:struct {
    private struct Slot {public long Sequence;public T Value;}
    private readonly Slot[] slots;
    private readonly int mask;
    private long write,read;
    public int Capacity=>slots.Length;
    public CommandQueue(int capacity) {
        if(capacity<2||(capacity&(capacity-1))!=0)throw new ArgumentOutOfRangeException(nameof(capacity));
        slots=new Slot[capacity];mask=capacity-1;
        for(int i=0;i<capacity;i++)slots[i].Sequence=i;
    }
    public bool TryEnqueue(T value) {
        long position=Volatile.Read(ref write);
        while(true) {
            ref var slot=ref slots[(int)(position&mask)];
            long difference=Volatile.Read(ref slot.Sequence)-position;
            if(difference==0) {
                if(Interlocked.CompareExchange(ref write,position+1,position)==position) {
                    slot.Value=value;Volatile.Write(ref slot.Sequence,position+1);return true;
                }
            } else if(difference<0)return false;
            position=Volatile.Read(ref write);
        }
    }
    public bool TryDequeue(out T value) {
        long position=read;ref var slot=ref slots[(int)(position&mask)];
        if(Volatile.Read(ref slot.Sequence)!=position+1){value=default;return false;}
        value=slot.Value;slot.Value=default;Volatile.Write(ref slot.Sequence,position+slots.Length);read=position+1;return true;
    }
}
