using KeyWoo.Core;
using Xunit;
namespace KeyWoo.Tests;
public sealed class CommandQueueTests {
    [Fact] public void FullQueueRejectsWithoutOverwritingUnreadCommands(){var q=new CommandQueue<int>(4);for(int i=0;i<4;i++)Assert.True(q.TryEnqueue(i));Assert.False(q.TryEnqueue(99));for(int i=0;i<4;i++){Assert.True(q.TryDequeue(out int value));Assert.Equal(i,value);}Assert.False(q.TryDequeue(out _));Assert.True(q.TryEnqueue(5));Assert.True(q.TryDequeue(out int next));Assert.Equal(5,next);}
    [Fact] public async Task TwoProducersNeverTearOrDuplicateCommandsAcrossWraps(){var q=new CommandQueue<(int Producer,int Index)>(256);var seen=new HashSet<(int,int)>();int done=0;Task Producer(int id)=>Task.Run(()=>{for(int i=0;i<3000;i++){while(!q.TryEnqueue((id,i)))Thread.Yield();}Interlocked.Increment(ref done);});var a=Producer(0);var b=Producer(1);var deadline=DateTime.UtcNow.AddSeconds(5);while(seen.Count<6000&&DateTime.UtcNow<deadline){if(q.TryDequeue(out var item))Assert.True(seen.Add(item));else Thread.Yield();}await Task.WhenAll(a,b).WaitAsync(TimeSpan.FromSeconds(1));Assert.Equal(2,done);Assert.Equal(6000,seen.Count);}
}
